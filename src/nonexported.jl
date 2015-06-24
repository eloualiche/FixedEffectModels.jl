##############################################################################
##
## Demean functions (will export when DataFrames are in better shape)
##
##############################################################################


function helper_demean!(out::AbstractDataFrame, df::AbstractDataFrame, cols::Vector{Symbol}, absorb::Formula)
	
	# construct subdataframe wo NA
	condition = complete_cases(df)
	subdf = sub(df, condition)
	
	# construct an array of factors
	push!(factors, construct_fe(subdf, DataFrames.Terms(absorb).terms, sqrtw))

	# case where only interacted fixed effect : add constant
	if all(map(z -> typeof(z) <: FeInteracted, factors))
		push!(factors, Fe(PooledDataArray(fill(1, size(subdf, 1))), sqrtw, :cons))
	end
	
	# demean each vector sequentially
	for x in cols
		v = demean_vector(subdf[x], factors)
		out[x] = DataVector(eltype(v), size(out, 1))
		out[condition, x] = v
	end
	out
end

function helper_demean!(out::AbstractDataFrame, df::AbstractDataFrame, cols::Vector{Symbol})
	# construct subdataframe wo NA
	condition = complete_cases(df)
	subdf = sub(df, condition)
	for x in cols
		out[condition, x] = subdf[x] .- mean(subdf[x])
		out[!condition, x] = NA
	end
	return(out)
end

#
# Exported function
#

function demean!(df::AbstractDataFrame, cols::Vector{Symbol}, absorb::Formula)
	helper_demean!(df, df, cols, absorb)
end

function demean(df::AbstractDataFrame, cols::Vector{Symbol}, absorb::Formula)
	out = DataFrame(Float64, size(df, 1), length(cols))
	names!(out, cols)
	helper_demean!(out, df, cols, absorb)
	out
end

function demean!(df::AbstractDataFrame, cols::Vector{Symbol})
	helper_demean(df, df, cols)
end

function demean(df::AbstractDataFrame, cols::Vector{Symbol})
	out = DataFrame(Float64, size(df, 1), length(cols))
	names!(out, cols)
	helper_demean!(out, df, cols)
end


##############################################################################
##
## Factor models (Bai 2009)
##
##############################################################################





type FactorModel <: FeModel
    id::Symbol
    time::Symbol
    dimension::Int64
end

type FactorStructure
    id::PooledDataArray
    time::PooledDataArray
    lambda::Matrix{Float64} 
    f::Matrix{Float64}
end

type FactorEstimate
    coef::Vector{Float64} 
    factor::FactorStructure
end


# Bai 2009
function fit(m::InteractiveFeModel, df::AbstractDataFrame, factor::FactorModel, vce::AbstractVce = VceSimple())

    t = DataFrames.Terms(f)
    hasfe = (typeof(t.terms[1]) == Expr) && t.terms[1].args[1] == :|
    if hasfe
        absorbexpr = t.terms[1].args[3]
        absorbf = Formula(nothing, absorbexpr)
        absorbvars = unique(DataFrames.allvars(absorbexpr))
        rexpr = t.terms[1].args[2]
        rf = Formula(f.lhs, rexpr)
        rvars = unique(DataFrames.allvars(rf))
    else
        rf = f
        rvars = unique(DataFrames.allvars(f))
        absorbvars = nothing
    end
    rt = DataFrames.Terms(rf)
    vcevars = DataFrames.allvars(vce)
    allvars = setdiff(vcat(rvars, absorbvars, vcevars, factor.id, factor.time), [nothing])
    allvars = unique(convert(Vector{Symbol}, allvars))

    # construct df without NA for all variables
    esample = complete_cases(df[allvars])
    df = df[esample, allvars]
    for v in allvars
        dropUnusedLevels!(df[v])
    end

    # create weight vector
    w = fill(one(Float64), size(df, 1))
    sqrtw = w




    # demean all variables
    if hasfe
        # construct an array of factors
        factors = AbstractFe[]
        for a in DataFrames.Terms(absorbf).terms
            push!(factors, construct_fe(df, a, sqrtw))
        end

        # in case where only interacted fixed effect, add constant
        if all(map(z -> typeof(z) <: FeInteracted, factors))
            push!(factors, Fe(PooledDataArray(fill(1, size(df, 1))), sqrtw, :cons))
        end

        # demean each vector sequentially
        for x in rvars
            if weight == nothing
                df[x] = demean_vector(factors, df[x])
            else
                dfx = df[x]
                for i in 1:length(dfx)
                    @inbounds dfx[i] *= sqrtw[i]
                end
                df[x] = demean_vector(factors, dfx) 
                for i in 1:length(dfx)
                    @inbounds dfx[i] /= sqrtw[i]
                end
            end
        end
    else
        print(rvars)
        for x in rvars
            df[x] = df[x] .- mean(df[x])
        end
    end
    # remove the intercept
    rt = deepcopy(rt)
    rt.intercept = false


    df1 = DataFrame(map(x -> df[x], rt.eterms))
    names!(df1, convert(Vector{Symbol}, map(string, rt.eterms)))
    mf = ModelFrame(df1, rt, esample)
    mm = ModelMatrix(mf)
    coefnames = DataFrames.coefnames(mf)

    y = model_response(mf)::Vector{Float64}
    X = mm.m::Matrix{Float64}
    H = At_mul_B(X, X)
    M = A_mul_Bt(inv(cholfact!(H)), X)
    b = M * y

    # get factors
    factor_estimate = estimate_factor_model(b, X, M,  y, df[factor.id], df[factor.time], factor.dimension) 
end


function estimate_factor_model(b::Vector{Float64}, X::Matrix{Float64}, M::Matrix{Float64}, y::Vector{Float64}, id::PooledDataArray, time::PooledDataArray, d::Int64) 
    res_vector = Array(Float64, length(y))
    # initialize at zero for missing values
    res_matrix = fill(zero(Float64), (length(id.pool), length(time.pool)))
    Lambda = Array(Float64, (length(id.pool), d))
    F = Array(Float64, (length(time.pool), d) )
    max_iter = 10000
    tolerance = 1e-8 * length(y)
    iter = 0
    while iter < max_iter
        iter += 1
        oldb = copy(b)
        # Compute predicted(regressor)
        A_mul_B!(res_vector, X, b)
        @simd for i in 1:length(y)
            @inbounds res_matrix[id.refs[i], time.refs[i]] = y[i] - res_vector[i]
        end
        svdresult = svdfact!(res_matrix) 
        A_mul_B!(Lambda, sub(svdresult.U, :, 1:d), diagm(sub(svdresult.S, 1:d)))
        A_mul_B!(res_matrix, Lambda, sub(svdresult.Vt, 1:d, :))
        @simd for i in 1:length(y)
            @inbounds res_vector[i] = y[i] - res_matrix[id.refs[i], time.refs[i]]
        end      
        # regress y - predicted(factor) over X
        b = M * res_vector
        error = euclidean(b, oldb)
        if error < tolerance
            println(iter)
            F = transpose(sub(svdresult.Vt, 1:d, :))
            # normalize
            break
        end
    end
    scale!(Lambda, 1 / sqrt(length(time.pool)))
    scale!(F, sqrt(length(time.pool)))
    FactorEstimate(b, FactorStructure(id, time, Lambda, F))
end


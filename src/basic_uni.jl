import Base: sqrt, exp, log, sin, tanh, -, abs, abs2, sign

cuda1 = [
"sqrt",
# "rsqrt",
# "cbrt",
# "rcbrt",
"exp",
# "exp2",
# "exp10",
# "expm1",
"log",
# "log2",
# "log10",
# "log1p",
"sin",
# "cos",
# "tan",
# "sinpi",
# "cospi",
# "asin",
# "acos",
# "atan",
# "sinh",
# "cosh",
"tanh",
# "asinh",
# "acosh",
# "atanh",
# "erf",
# "erfc",
# "erfinv",
# "erfcinv",
# "erfcx",
# "normcdf",
# "normcdfinv",
# "lgamma",
# "tgamma",
# "logb",
# "ilogb",
# "j0",
# "j1",
# "y0",
# "y1",
# "cyl_bessel_i0",
# "cyl_bessel_i1",
# "trunc",
# "round",
# "rint",
# "nearbyint",
# "ceil",
# "floor",
# "lrint",
# "lround",
# "llrint",
# "llround",
("neg", "-", "-xi"),
("invx", "invx", "1/xi"),
("relu", "relu", "(xi>0?xi:0)"),
("sigm", "sigm", "1/(1+exp(-xi))"),
("abs", "abs", "(xi<0?-xi:xi)"),
("abs2", "abs2", "(xi*xi)"),
("sign", "sign", "(xi>0?1:xi<0?-1:0)"),
]

function cuda1def(f, j=f, o...)
    J=Symbol(j)
    for S in (32,64)
        T = Symbol("Float$S")
        F = "$(f)_$S"
        @eval begin
            function $J(x::DexArray{$T})
                y = similar(x)
                ccall(($F,$libcudex),Void,(Cint,Ptr{$T},Ptr{$T}),length(y),x,y)
                return y
            end
        end
    end
end

#if isdefined(:libcudex)
    for f in cuda1
        isa(f,Tuple) || (f=(f,))
        cuda1def(f...)
    end
#end

# Define some common operations as primitives for efficiency:
# 1. Avoid creating intermediate arrays
# 2. Avoid taking derivatives of intermediate operations

for (f,g,y,dx) in ((:invx, :invxback, :(one(T)/x[i]), :(-y[i]*y[i]*dy[i])),
                   (:relu, :reluback, :(max(zero(T),x[i])), :(ifelse(y[i]>0,dy[i],zero(T)))),
                   (:sigm, :sigmback, :(one(T)/(one(T)+exp(-x[i]))), :(dy[i]*y[i]*(one(T)-y[i]))),
                   (:tanx, :tanhback, :(tanh(x[i])), :(dy[i]*(one(T)-y[i]*y[i]))),
                   )
    @eval begin
        function $f{T<:AbstractFloat}(x::Array{T})
            y = similar(x)
            @inbounds for i=1:length(y)
                y[i] = $y
            end
            return y
        end
        function $g{T<:AbstractFloat}(dy::Array{T},y::Array{T})
            dx = similar(dy)
            @inbounds for i=1:length(dx)
                dx[i] = $dx
            end
            return dx
        end
        # @primitive $f(x),dy,y $g(dy,y)
    end
end

# To avoid conflict with AutoGrad:
# @primitive tanh(x::Array),dy,y     tanhback(dy,y)
# @primitive tanh(x::DexArray),dy,y tanhback(dy,y)
# @primitive tanhback(dy,y),ddx  ddx.*(1.-y.*y)  ddx.*(-2.*dy.*y)

# Math for the cross-entropy loss: x is unnormalized input, p is
# target probabilities, q is estimated probabilities. Read left column
# down, right column (loss gradients) back up.

# x			dx = -p + qz/z = -p + exp(logq)
# xmax  = max(x,1)	-sum(db)=0
# logqz = x .- xmax	-p + qz/z
# qz    = exp(logqz)	rep(1/z)
# z     = sum(qz,1)	1/z
# logz  = log(z)	sum(p)=1
# logq  = logqz.-logz	-p
# plogq = p .* logq	-1
# loss  = -sum(plogq)	1

"""

logp(x,[dims]) treats entries in x as as unnormalized logp and returns
normalized logp.  If dims is not specified the normalization is over
the whole x, otherwise the normalization is performed over the given
dimensions.  In particular dims=1 normalizes columns of x and dims=2
normalizes rows of x.

"""
function logp(x,d...)
    x = x .- maximum(x,d...)
    x = x .- log(sum(exp(x),d...))
end

# dy should be -p and y=logq so this should give us -p+q
# @primitive  logp(x,d...),dy,y  (dy - exp(y).*sum(dy,d...))

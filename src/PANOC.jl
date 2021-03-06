module PANOC

const RealOrComplex{R} = Union{R, Complex{R}}

const ArrayOrTuple{R} = Union{
	AbstractArray{C, N} where {C <: RealOrComplex{R}, N},
	Tuple{Vararg{AbstractArray{C, N} where {C <: RealOrComplex{R}, N}}}
}

const Maybe{T} = Union{T, Nothing}

using ProximalOperators
using Printf
using Base.Iterators

export panoc

include("LBFGS.jl")
include("IterativeMethodsTools.jl")

struct PANOC_iterable{R <: Real, Tf, TA, Tg, Tx}
	f::Tf             # smooth term
	A::TA             # matrix/linear operator
	g::Tg             # (possibly) nonsmooth, proximable term
	x0::Tx            # initial point
	alpha::R          # in (0, 1), e.g.: 0.95
	beta::R           # in (0, 1), e.g.: 0.5
	L::Maybe{R}       # Lipschitz constant of the gradient of x ↦ f(Ax)
	adaptive::Bool    # enforce adaptive stepsize even if L is provided
	memory::Int       # memory parameter for L-BFGS
end

mutable struct PANOC_state{R <: Real, Tx, TAx}
	x::Tx             # iterate
	Ax::TAx           # A times x
	f_Ax::R           # value of smooth term
	grad_f_Ax::Tx     # gradient of f at Ax
	At_grad_f_Ax::TAx # gradient of smooth term
	gamma::R          # stepsize parameter of forward and backward steps
	y::Tx             # forward point
	z::Tx             # forward-backward point
	g_z::R            # value of nonsmooth term (at z)
	res::Tx           # fixed-point residual at iterate (= z - x)
	H::LBFGS{R}       # variable metric
	tau::Maybe{R}     # stepsize (can be nothing since the initial state doesn't have it)
	# some additional storage:
	d::Tx
	Ad::TAx
	x_d::Tx
	Ax_d::TAx
	f_Ax_d::R
	grad_f_Ax_d::Tx
	At_grad_f_Ax_d::TAx
	z_curr::Tx
end

PANOC_state(x::Tx, Ax::TAx, f_Ax::R, grad_f_Ax, At_grad_f_Ax, gamma, y, z, g_z, res, H, tau) where {R, Tx, TAx} =
	PANOC_state{R, Tx, TAx}(x, Ax, f_Ax, grad_f_Ax, At_grad_f_Ax, gamma, y, z, g_z, res, H, tau,
							zero(x), zero(Ax), zero(x), zero(Ax), zero(R), zero(Ax), zero(x), zero(x))

f_model(f_x, grad_f_x, res, gamma) = f_x - real(dot(grad_f_x, res)) + (0.5/gamma)*norm(res)^2

f_model(state::PANOC_state) = f_model(state.f_Ax, state.At_grad_f_Ax, state.res, state.gamma)

import Base: iterate

function iterate(iter::PANOC_iterable{R}) where R
	x = iter.x0
	Ax = iter.A * x
	grad_f_Ax, f_Ax = gradient(iter.f, Ax)

	L = iter.L
	if L === nothing
		# compute lower bound to Lipschitz constant of the gradient of x ↦ f(Ax)
		xeps = x .+ one(R)
		grad_f_Axeps, f_Axeps = gradient(iter.f, iter.A*xeps)
		L = norm(iter.A' * (grad_f_Axeps - grad_f_Ax)) / sqrt(length(x))
	end

	gamma = iter.alpha/L

	# compute initial forward-backward step
	At_grad_f_Ax = iter.A' * grad_f_Ax
	y = x - gamma .* At_grad_f_Ax
	z, g_z = prox(iter.g, y, gamma)

	# compute initial fixed-point residual
	res = x - z

	# initialize variable metric
	H = LBFGS(x, iter.memory)

	state = PANOC_state(x, Ax, f_Ax, grad_f_Ax, At_grad_f_Ax, gamma, y, z, g_z, res, H, nothing)

	return state, state
end

function iterate(iter::PANOC_iterable{R}, state::PANOC_state{R, Tx, TAx}) where {R, Tx, TAx}
	Az, f_Az, grad_f_Az, At_grad_f_Az = nothing, nothing, nothing, nothing
	a, b, c = nothing, nothing, nothing

	f_Az_upp = f_model(state)

	# backtrack gamma (warn and halt if gamma gets too small)
	while iter.L === nothing || iter.adaptive == true
		if state.gamma < 1e-7 # TODO: make this a parameter?
			@warn "parameter `gamma` became too small ($(state.gamma)), stopping the iterations"
			return nothing
		end
		Az = iter.A*state.z
		grad_f_Az, f_Az = gradient(iter.f, Az)
		tol = 10*eps(R)*(1 + abs(f_Az))
		if f_Az <= f_Az_upp + tol break end
		state.gamma *= 0.5
		state.y .= state.x .- state.gamma .* state.At_grad_f_Ax
		state.g_z = prox!(state.z, iter.g, state.y, state.gamma)
		state.res .= state.x .- state.z
		reset!(state.H)
		f_Az_upp = f_model(state)
	end

	# compute FBE
	FBE_x = f_Az_upp + state.g_z

	# update metric
	update!(state.H, state.x, state.res)

	# compute direction
	mul!(state.d, state.H, -state.res)

	# backtrack tau 1 → 0
	tau = one(R)
	mul!(state.Ad, iter.A, state.d)

	state.x_d .= state.x .+ state.d
	state.Ax_d .= state.Ax .+ state.Ad
	state.f_Ax_d = gradient!(state.grad_f_Ax_d, iter.f, state.Ax_d)
	mul!(state.At_grad_f_Ax_d, adjoint(iter.A), state.grad_f_Ax_d)

	state.x .= state.x_d
	state.Ax .= state.Ax_d
	state.f_Ax = state.f_Ax_d
	state.grad_f_Ax .= state.grad_f_Ax_d
	state.At_grad_f_Ax .= state.At_grad_f_Ax_d

	copyto!(state.z_curr, state.z)

	sigma = iter.beta * (0.5/state.gamma) * (1 - iter.alpha)
	tol = 10*eps(R)*(1 + abs(FBE_x))
	threshold = FBE_x - sigma * norm(state.res)^2 + tol

	for i = 1:10
		state.y .= state.x .- state.gamma .* state.At_grad_f_Ax
		state.g_z = prox!(state.z, iter.g, state.y, state.gamma)
		state.res .= state.x .- state.z
		FBE_x_new = f_model(state) + state.g_z

		if FBE_x_new <= threshold
			state.tau = tau
			return state, state
		end

		if Az === nothing Az = iter.A * state.z_curr end

		tau *= 0.5
		state.x .= tau .* state.x_d .+ (1-tau) .* state.z_curr
		state.Ax .= tau .* state.Ax_d .+ (1-tau) .* Az

		if ProximalOperators.is_quadratic(iter.f)
			# in case f is quadratic, we can compute its value and gradient
			# along a line using interpolation and linear combinations
			# this allows saving operations
			if grad_f_Az === nothing grad_f_Az, f_Az = gradient(iter.f, Az) end
			if At_grad_f_Az === nothing
				At_grad_f_Az = iter.A' * grad_f_Az
				c = f_Az
				b = dot(state.Ax_d .- Az, grad_f_Az)
				a = state.f_Ax_d - b - c
			end
			state.f_Ax = a * tau^2 + b * tau + c
			state.grad_f_Ax .= tau .* state.grad_f_Ax_d .+ (1-tau) .* grad_f_Az
			state.At_grad_f_Ax .= tau .* state.At_grad_f_Ax_d .+ (1-tau) .* At_grad_f_Az
		else
			# otherwise, in the general case where f is only smooth, we compute
			# one gradient and matvec per backtracking step
			state.f_Ax = gradient!(state.grad_f_Ax, iter.f, state.Ax)
			mul!(state.At_grad_f_Ax, adjoint(iter.A), state.grad_f_Ax)
		end
	end

	@warn "stepsize `tau` became too small ($(tau)), stopping the iterations"
	return nothing
end

"""
	panoc(f, A, g, x0, [L, adaptive, memory, maxit, tol, verbose, freq])

Minimizes f(A*x) + g(x) with respect to x, starting from x0, using PANOC.
Optional keyword arguments:
* `L::Real` (default: `nothing`), the Lipschitz constant of the gradient of x ↦ f(Ax).
* `adaptive::Bool` (default: `false`), if true, forces the method stepsize to be adaptively adjusted even if `L` is provided (this behaviour is always enforced if `L` is not provided).
* `memory::Integer` (default: `5`), memory parameter for L-BFGS.
* `maxit::Integer` (default: `1000`), maximum number of iterations to perform.
* `tol::Real` (default: `1e-8`), absolute tolerance on the fixed-point residual.
* `verbose::Bool` (default: `true`), whether or not to print information during the iterations.
* `freq::Integer` (default: `10`), frequency of verbosity.
"""
function panoc(f, A, g, x0;
	L=nothing, adaptive=false,
	memory=5, maxit=1000, tol=1e-8,
	verbose=true, freq=10,
	alpha=0.95, beta=0.5)

	stop(state::PANOC_state) = norm(state.res, Inf)/state.gamma <= tol
	disp((it, state)) = @printf "%5d | %.3e | %.3e | %.3e\n" it state.gamma norm(state.res, Inf)/state.gamma (state.tau === nothing ? 0.0 : state.tau)

	iter = PANOC_iterable(f, A, g, x0, alpha, beta, L, adaptive, memory)
	iter = take(halt(iter, stop), maxit)
	iter = enumerate(iter)
	if verbose iter = tee(sample(iter, freq), disp) end

	num_iters, state_final = loop(iter)

	return state_final.z, num_iters
end

end # module

module OSSDP

using Formatting, Projections, Scaling, OSSDPTypes
export solveSDP, sdpResult, sdpDebug, sdpSettings


  function isPrimalInfeasible(δy::Array{Float64},A,l::Array{Float64},u::Array{Float64},ϵ_prim_inf::Float64)
    norm_δy = norm(δy,Inf)
    if norm_δy > ϵ_prim_inf
      δy = δy/norm_δy
      # second condition
      if (u'*max.(δy,0) + l'*min.(δy,0) )[1] <= - ϵ_prim_inf*norm_δy
        # first condition
          if norm(A'*δy,Inf) <= ϵ_prim_inf*norm_δy
           return true
          end
        end
      end
      return false
  end


  function isDualInfeasible(δx::Array{Float64},P,A,q::Array{Float64},l::Array{Float64},u::Array{Float64},ϵ_dual_inf::Float64)
    norm_δx = norm(δx,Inf)
    m = size(A,1)
    if norm_δx > ϵ_dual_inf
      if (q'*δx)[1] < - ϵ_dual_inf*norm_δx
        if norm(P*δx,Inf) < ϵ_dual_inf*norm_δx
          Aδx = A * δx
          for i = 1:m
            if ( (u[i] < 1e18) && (Aδx[i] > ϵ_dual_inf*norm_δx) ) || ( (l[i] > -1e18) && (Aδx[i] < - ϵ_dual_inf*norm_δx) )
              return false
            end
          end
          return true
        end
      end
    end
    return false
  end

  function calculateResiduals(x::Array{Float64,1},s::Array{Float64,1},λ::Array{Float64,1},ν::Array{Float64,1},p::OSSDPTypes.problem)
        n = p.n
        m = p.m
        H = [p.A zeros(m,n); eye(n) -eye(n)]
        u = [x;s]
        r_prim = norm(H*u-[p.b;zeros(n)],Inf)
        # ∇f0 + ∑ νi ∇hi(x*) == 0 condition
        r_dual = norm(p.P*x + p.q + λ + p.A'*ν,Inf)
    return r_prim,r_dual
  end
# SOLVER ROUTINE
# -------------------------------------
  function solveSDP(P::Array{Float64,2},q::Array{Float64,1},A::Array{Float64,2},b::Array{Float64,1},settings::OSSDPTypes.sdpSettings)

    #Load algorithm settings
    σ = settings.sigma
    α = settings.alpha
    ρ = settings.rho
    ϵ_abs = settings.eps_abs
    ϵ_rel = settings.eps_rel
    ϵ_prim_inf = settings.eps_prim_inf
    ϵ_dual_inf = settings.eps_dual_inf

    # populate problem type
    p = problem(P,q,A,b,size(b,1),size(q,1))
    sm = scaleMatrices()

    # instantiate variables
    iter = 0
    status = "unsolved"

    # determine size of decision variables
    # n: r^2 since we are working with vectorized matrixes of size r
    n = p.n
    r = Int(sqrt(n))
    m = p.m

    x = zeros(n)
    s = zeros(n)
    λ = zeros(n)
    ν = zeros(m)

    cost = Inf

    # create debugging variables
    xArr = zeros(settings.max_iter,n)
    sArr = zeros(settings.max_iter,n)
    λArr = zeros(settings.max_iter,n)
    costArr = zeros(settings.max_iter)
    νArr = zeros(settings.max_iter,m)

    # scale problem data
    # if settings.scaling != 0
    #   scaleProblem!(p,scaleMatrices,settings)
    # end

    # TODO: Print information still true?
    # print information about settings to the screen
    println("-"^50 * "\n" * " "^8 * "ADMM-SDP Solver in pure Julia\n" * " "^18 * "Michael Garstka\n"  * " "^8 * "University of Oxford, January 2018\n" * "-"^50 * "\n")
    println("Problem: variable vec(X) size: n = $(n), constraints m = $(m)")
    println("Settings: ϵ_abs = $(ϵ_abs), ϵ_rel = $(ϵ_rel),\n" * " "^10 * "ϵ_prim_inf = $(ϵ_prim_inf), ϵ_dual_inf = $(ϵ_dual_inf),\n" * " "^10 * "ρ = $(ρ), σ = $(σ), α = $(α),\n" * " "^10 * "max_iter = $(settings.max_iter)\n\n")

    tic()

    # KKT matrix M
    M = [p.P+σ*eye(n) p.A';p.A -(1/ρ)*eye(m)]
    M = sparse(M)

    # Do LDLT Factorization: A = LDL^T
    F = ldltfact(M)

    for iter = 1:1:settings.max_iter

      # assign previous variables, here x(n+1) becomes the new x(n), s(n+1) -> x(n)

      # construct right hand side [-q+σ*s(n)-λ(n); b-(1/ρ)*ν(n)]
      RHS = [-p.q+σ*s-λ; p.b-(1/ρ)*ν]

      #solve linear system M*k = b with help of factorization matrix
      k = F\RHS

      # The relaxation definitely has to be double checked
      #deconstruct solution vector k = [x(n+1);ν(n+1)]
      x = k[1:n]
      ν = k[n+1:end]

      # Projection steps and relaxation xRelax = αx(n+1)+(1-α)s(n)
      xRelax = α*x+(1-α)*s

      #TODO: SCS uses approximate projection (see Paper)
      # s(n+1) = Proj( xRelax + (1/σ)*λ(n))
      s = Projections.sdcone( xRelax + (1/σ)*λ,r)


      # update dual variables λ(n+1) = λ(n) + σ*(xRelax - s(n+1))
      λ = λ + σ*(xRelax - s)

      # update cost
      cost = (1/2 * x'*p.P*x + p.q'*x)[1]

      # compute residuals (based on optimality conditions of the problem) to check for termination condition
      # compute them every {settings.checkTermination} step
      if mod(iter,settings.checkTermination)  == 0
        r_prim,r_dual = calculateResiduals(x,s,λ,ν,p)
      else
        r_prim = NaN
        r_dual = NaN
      end
      # complementary slackness condition
      # store variables
      xArr[iter,:] = x
      sArr[iter,:] = s
      λArr[iter,:] = λ
      costArr[iter] = cost
      νArr[iter,:] = ν

      # compute deltas
      # δx = xNew - xPrev
      # δy = yNew - yPrev

      # print iteration steps
      if settings.verbose
        if iter == 1
          println("Iter:\tObjective:\tPrimal Res 1:\tDual Res:")
        end
        if mod(iter,100) == 0 || iter == 1 || iter == 2 || iter == settings.max_iter
          printfmt("{1:d}\t{2:.4e}\t{3:.4e}\t{4:.4e}\n", iter,cost,r_prim,r_dual)
       end
      end

      # if isPrimalInfeasible(δy,A,l,u,ϵ_prim_inf)
      #     status = "primal infeasible"
      #     cost = Inf
      #     xNew = NaN*ones(n,1)
      #     yNew = NaN*ones(m,1)
      #     break
      # end

      # if isDualInfeasible(δx,P,A,q,l,u,ϵ_dual_inf)
      #     status = "dual infeasible"
      #     cost = -Inf
      #     xNew = NaN*ones(n,1)
      #     yNew = NaN*ones(m,1)
      #     break
      # end

      # check convergence with residuals every {settings.checkIteration} step
      if mod(iter,settings.checkTermination) == 0
        H = [p.A zeros(m,n); eye(n) -eye(n)]
        u = [x;s]
        ϵ_prim = ϵ_abs + ϵ_rel * max.(norm(H*u,Inf), norm(p.b,Inf),1 )
        ϵ_dual = ϵ_abs + ϵ_rel * max.(norm(p.P*x,Inf), norm(p.q,Inf), norm(λ,Inf),1 )
        if ( r_prim < ϵ_prim  && r_dual < ϵ_dual)
          if settings.verbose
            printfmt("{1:d}\t{2:.4e}\t{3:.4e}\t{4:.4e}\n", iter,cost,r_prim,r_dual)
          end
          status = "solved"
          break
        end
      end
    end

    # print solution to screen
    rt = toq()
    println("\n\n" * "-"^50 * "\nRESULT: Status: $(status)\nTotal Iterations: $(iter)\nOptimal objective: $(round.(cost,4))\nRuntime: $(round.(rt,3))s ($(round.(rt*1000,2))ms)\n" * "-"^50 )

    # calculate primal and dual residual
    if iter == settings.max_iter
      r_prim,r_dual = calculateResiduals(x,s,λ,ν,p)
    end
    # create result object
    result = sdpResult(x,s,λ,cost,iter,status,rt,r_prim,r_dual);

    dbg = sdpDebug(xArr,sArr,λArr,νArr,costArr)

    return result,dbg;

  end

end





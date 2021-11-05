import Pkg

Pkg.activate(".")
Pkg.instantiate()

include("src/SimklMedusaSync.jl")

using .SimklMedusaSync

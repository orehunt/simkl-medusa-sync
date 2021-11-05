import Pkg

Pkg.activate(".")
include("src/SimklMedusaSync.jl")

using .SimklMedusaSync

SimklMedusaSync.run()

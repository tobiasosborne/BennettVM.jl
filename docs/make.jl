# Documenter.jl wiring for BennettVM.jl. Local-only build — no deploydocs, no
# GitHub CI (per CLAUDE.md). BennettVM depends on Bennett.jl (a path dep), so the
# docs environment must `dev` both packages before building.
#
# Build:
#   cd docs
#   julia --project -e 'using Pkg; Pkg.develop(path="../../Bennett.jl"); Pkg.develop(path=".."); Pkg.instantiate()'
#   julia --project make.jl
#   # -> open docs/build/index.html
#
# Doctests are disabled (doctest=false): the VM round-trip examples use plain
# ```julia fences rather than executed ```jldoctest fences, because the
# interpreter's outputs are not pinned here.

using Documenter
using BennettVM

DocMeta.setdocmeta!(BennettVM, :DocTestSetup, :(using BennettVM); recursive = true)

makedocs(
    sitename = "BennettVM.jl",
    modules = [BennettVM],
    authors = "Tobias Osborne",
    pages = [
        "Home" => "index.md",
        "Getting started" => [
            "Quick start" => "getting_started/quickstart.md",
        ],
        "Explanation" => [
            "What BennettVM is" => "explanation/what_is_bennettvm.md",
            "Instruction set & state model" => "explanation/instruction_set.md",
            "The reversibility model" => "explanation/reversibility_model.md",
            "Integration with Bennett.jl" => "explanation/integration.md",
        ],
        "Reference" => [
            "API" => "reference/api.md",
        ],
    ],
    doctest = false,
    checkdocs = :none,
    warnonly = [:missing_docs, :cross_references, :docs_block],
    format = Documenter.HTML(prettyurls = false),
)

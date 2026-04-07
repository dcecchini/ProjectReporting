#!/usr/bin/env julia

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using ArgParse
using ProjectReporting
include("../webapp/App.jl")
using .App

function main()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--host"
            help = "Host interface to bind"
            arg_type = String
            default = "127.0.0.1"

        "--port"
            help = "Port to listen on"
            arg_type = Int
            default = 8000
    end

    args = parse_args(s)

    host = args["host"]
    port = args["port"]

    println("Starting Genie app on $host:$port ...")
    App.serve(host=host, port=port)
end

main()

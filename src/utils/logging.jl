module LoggingConfig

using Logging
using LoggingExtras
using Dates
using ProjectReporting.Config

export init_logger

function log_formatter(io, args)
    ts = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")

    level   = args.level
    message = args.message
    mod     = args._module
    file    = args.file
    line    = args.line

    print(io,
        "[$ts] ",
        "[", level, "] ",
        "[", mod, "] ",
        message
    )

    # Print structured fields (kwargs)
    for (k, v) in pairs(args.kwargs)
        print(io, " ", k, "=", repr(v))
    end

    println(io)
end

function init_logger(log_level::LogLevel=Config.LOG_LEVEL, log_dir::String=Config.LOG_DIR)
    mkpath(log_dir)

    logfile = joinpath(log_dir, "app-$(Dates.today()).log")

    file_logger = FormatLogger(log_formatter, open(logfile, "a"))
    console_logger = FormatLogger(log_formatter, stdout)

    combined = TeeLogger(console_logger, file_logger)

    global_logger(MinLevelLogger(combined, log_level))

    @info "Logger initialized" logfile log_level
end

end
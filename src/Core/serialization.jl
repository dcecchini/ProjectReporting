module Serialization

export to_dict, from_dict

# -------------------------------
# Generic fallbacks (optional)
# -------------------------------
to_dict(x) = error("to_dict not implemented for $(typeof(x))")

from_dict(::Type{T}, d) where {T} =
    error("from_dict not implemented for $T")

end
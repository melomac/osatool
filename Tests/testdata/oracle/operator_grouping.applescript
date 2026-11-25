on equalities(a, b, c)
    return {(a = b) = c, a = (b = c), (a < b) = c, a = (b < c), (a = b) < c, a < (b = c), (a < b) < c, a < (b < c)}
end equalities

on containments(a, b, c)
    return {(a contains b) = c, a contains (b = c), (a = b) contains c, (a < b) contains c, a < (b contains c), (a starts with b) ends with c, a starts with (b ends with c)}
end containments

on coercions(a, b, c)
    return {a = (b as text), (a = b) as text, (a as text) = b, (a as text) as list, (a as text) & b, a & (b as text), (a & b) as text, (a + b) as text, a + (b as integer)}
end coercions

on negations(a, b, c)
    return {not (a = b), (not a) = b, a and not b, not (a and b), (not a) and b, a or not (b or c), not (not a)}
end negations

on arithmetic(a, b, c)
    return {(a ^ b) ^ c, a ^ (b ^ c), -(a ^ b), (-a) ^ b, a ^ -b, a - (b - c), (a - b) - c, a - (b + c), (a + b) * c, a / (b * c), a * b / c, a mod (b div c), (a & b) & c, a & (b & c)}
end arithmetic

on logic(a, b, c)
    return {(a or b) and c, a or (b and c), (a and b) or c, a and (b or c), (a or b) or c, a or (b or c), a = b and b = c, a < b or not (b < c)}
end logic

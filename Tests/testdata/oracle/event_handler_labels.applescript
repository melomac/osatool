on display dialog msg buttons btns default button def
    return msg
end display dialog

on open location theURL
    return theURL
end open location

on open theFiles
    return theFiles
end open

on choose from list choices with prompt p default items d
    return {p, d}
end choose from list

on idle
    return 5
end idle

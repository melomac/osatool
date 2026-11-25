# Snapshots

The expected output of the tool for every sample script:

| File                           | Command                              |
| ------------------------------ | ------------------------------------ |
| `<name>.disasm.txt`            | `disassemble <name>.scpt`            |
| `<name>.disasm.json`           | `disassemble --json <name>.scpt`     |
| `<name>.applescript`           | `decompile <name>.scpt`              |
| `<name>.strings.applescript`   | `decompile --pass strings`           |
| `seccon.wrapped.applescript`   | `decompile --no-unwrap seccon.scpt`  |

`Tests/ToolboxTests/SnapshotTests.swift` checks that the tool
still prints exactly these bytes. The files were first written by
applescript-tools 1.0.2, the project this tool started from.

`opcodes.txt` is not an output of the tool. It has one line for each
of the 256 opcode bytes: its mnemonic, the length of its instruction and
its operands, and what is kept of it when the code is cut off.
`Tests/BytecodeTests/OpcodeTableTests.swift` checks it, and writes it
again when the tests run with `OSATOOL_WRITE_OPCODES` set.

The decompiled source of the fixtures in `compiled/` is not repeated
here: `compiled/<name>.expected.applescript` already holds it.

When a change to the output is wanted, write the files again and review
the difference:

```sh
Scripts/update-snapshots.sh
git diff Tests/testdata/snapshots
```

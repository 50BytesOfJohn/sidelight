# Synthetic native OpenCode V2 fixture

Source pin: `anomalyco/opencode` tag `v2.0.27`, commit
`1f4d07a4a519185955ae8ab2ea3607805509e386`,
[generated schema](https://github.com/anomalyco/opencode/blob/1f4d07a4a519185955ae8ab2ea3607805509e386/packages/core/src/database/schema.gen.ts).
The project/session_v2 DDL was transcribed from that pin. All rows are invented.
No prompts, messages, events, registrations, credentials or vendor initialization.
The full upstream MIT notice is adjacent in OpenCode-LICENSE.txt.

OpenCodeSessionTests.swift resolves this file relative to #filePath. The UI fixture
seeder uses the same file. This directory is outside the SwiftPM test target source
directory and needs no generated or research files; include all three files in the
intended checkout. Research evidence is optional for test execution.

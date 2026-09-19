## 2026-09-16T12:52:40Z

You are an Explorer subagent for Milestone 1: Core Foundation, Storage & Security in amend.
Your assigned working directory is: /Users/fady/Dev/amend/.agents/m1_explorer_3
Maintain progress.md in your working directory and output your final recommendations to /Users/fady/Dev/amend/.agents/m1_explorer_3/handoff.md.

Read the authoritative specifications:
- /Users/fady/Dev/amend/ORIGINAL_REQUEST.md
- /Users/fady/Dev/amend/.agents/orchestrator_1/PROJECT.md
- /Users/fady/Dev/amend/CONTEXT.md
- /Users/fady/Dev/amend/docs/adr/0004-apfs-clone-first-project-media-storage.md
- /Users/fady/Dev/amend/.agents/spec_miner_fixtures_0/handoff.md

Your focus:
Investigate and design the security credential vault and Milestone 1 unit test specifications:
1. Keychain Credential Vault:
   - Service wrapper using macOS Keychain Services (kSecClassGenericPassword).
   - Supported service keys: ElevenLabs, Resemble, Gemini.
   - Methods: save(key:for:), get(keyFor:), delete(keyFor:), has(keyFor:).
   - Handling SecItemAdd, SecItemUpdate (errSecDuplicateItem handling), SecItemCopyMatching, SecItemDelete.
2. Project Bundle AST / Credential Leak Scanner:
   - Verification that project.json and .amend bundle never serialize plaintext API keys.
3. Unit Test suite design for Milestone 1:
   - StorageAPFSTests: testing APFS cloner vs bookmark fallback, project.json round-trip.
   - SecuritySuiteTests: testing Keychain CRUD round-trip, testing secret scanner against bundle contents.

Scope boundary:
You are an EXPLORER. Do NOT implement or write source code directly. Produce recommendations for the upcoming Worker.
When finished, write /Users/fady/Dev/amend/.agents/m1_explorer_3/handoff.md and send a completion message to the caller.

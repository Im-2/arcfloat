# Arcfloat build log

Times are Lagos (WAT). Never contains keys, seed phrases or tokens.

## Phase 0: repo and setup (Sat 2026-10-31)

| Time | Step | Result |
|---|---|---|
| ~16:40 | Prerequisites | node v24.15.0, npm 11.12.1, git 2.54.0, gh 2.100.0, Claude Code 2.1.288 (at `~/.local/bin/claude.exe`, not on PATH by default) |
| ~16:42 | Step 0.2: public repo | Created **https://github.com/Im-2/arcfloat** (public, personal account `Im-2`). First commit = `.gitignore`, `README.md`, `BUILD_LOG.md`, `EVIDENCE.md` only. Plan file is `PLAN (1).md`, so `.gitignore` also covers `PLAN*.md`. |
| ~16:45 | Arc Studio CLI | `@circle-fin/arc-studio-cli@1.2.2` installed globally (npm publisher: Circle maintainers) |
| ~16:46 | `arc-studio skills install --tool claude-code` | Plugin `arc-studio@arc-studio-cli` installed (user scope). Needs a Claude Code restart to activate. |
| ~16:47 | Circle skills | Marketplace `circlefin/skills` added; plugin `circle-skills@circle` installed (user scope) |
| ~16:47 | Circle MCP | `circle` HTTP MCP server added (local/project scope) |
| ~16:48 | Agent guide | Saved to `docs/ARC_STUDIO_AGENT_GUIDE.md` and read in full. It says contract deploys go to **Arc testnet by default**. `run` has no network flag. |
| ~16:48 | `arc-studio doctor` | Backend `https://studio.arc.io`, not authenticated at first |
| ~16:55 | `arc-studio login` | Human authorized in browser. `doctor`: creds file, auth ok |
| ~16:55 | `arc-studio usage` | **0%** of 30-day limit, scope user, no limit increase |

## Gate 0: mainnet path (Sat 2026-10-31, ~17:00)

- Session: `arcfloat`
- App id: `27858c7d-3db8-49c7-b2e1-fff69a7e2e87`
- Project URL: **https://studio.arc.io/app/27858c7d-3db8-49c7-b2e1-fff69a7e2e87**
- Prompt: "How do I deploy the contracts in this project to Arc mainnet from Studio, and what do I need to sign?" (question only, no code)
- Result: `completed`, no files changed, no deployments

Studio's answer (summary):
- **Studio cannot deploy to Arc mainnet.** Its built-in deploy is testnet-only, using a shared testnet wallet.
- A wallet connected in the Studio preview does not sign deploys. The Contracts panel is read-only.
- Studio can write and edit the contracts and the mainnet deploy config, and run tests and audits.
- Mainnet deploy = the human downloads the code and runs their own tooling (e.g. Foundry `forge create`) with their own wallet, outside Studio. The human signs one deploy tx per contract.
- Studio-reported mainnet RPC `https://rpc.mainnet.arc.io`. This is unverified; check it against docs.arc.io before use.

Live hackathon page re-checked: it matches the plan's snapshot (deadline widget 2026/11/02 04:59 UTC, text "close November 1"). It requires "built in Arc Studio and deployed to Arc mainnet" but does not say who signs the deploy.

Status: **Blocked on human decision** (plan section 2, Gate 0 step 4): approve the fallback (Studio builds and tests, human deploys the same contracts to mainnet from their own wallet), or not.

Human decision (Sat ~17:10): **fallback approved.** Studio builds and tests the contracts and app. The human deploys the same contracts to mainnet from their own wallet with Hardhat (npm, Windows), using a key in `.env` that Claude never reads. The human runs every deploy command. The app is hosted on Vercel for the public link. Commit after each gate.

## Phase 1: contracts and tests in Studio (Sat 2026-10-31)

| Time | Step | Result |
|---|---|---|
| ~17:15 | `arc-studio usage` | 0% |
| ~17:15 | Mainnet facts verified | Chain ID 5042, RPC, USDC `0x3600…0000` (6-decimal ERC-20 view; native view is 18 decimals) checked against docs.arc.io and the live chain. See `docs/ARC_NETWORK.md`. |
| ~17:15 | `arc-studio run --prompt-file prompts/01-contracts.txt --session arcfloat` | App `27858c7d-3db8-49c7-b2e1-fff69a7e2e87`. Status `completed`, nothing deployed. Studio ran a balanced security review, a Slither pass and the tests. |
| ~17:40 | Result | One contract, `Arcfloat` (no owner, no upgrade path, no fees, not payable; USDC address is a constructor arg, checked for 6 decimals). Foundry `forge test -vv`: **6 suites, 70 passed, 0 failed**. Fuzz 512 runs each; invariants 256 runs × depth 50. Full output: `studio/docs/arcfloat-test-output.md`. |
| ~17:40 | Review fix inside Studio | A blocklisted freelancer would have blocked the final funder's transaction. Studio fixed it: the advance push falls back to a claimable `freelancerOwed`. The fix is covered by a test and an invariant. |
| ~17:45 | Pulled locally | `arc-studio pull` → `studio/` (contracts, tests, mocks, scripts, foundry.toml). No local edits. |
| ~17:45 | `arc-studio usage` | 8% of the daily cap |

Studio's design decisions, noted for the README:
- In the funded path, funder shares add up to the full face amount, so the freelancer's "remainder" is 0. The freelancer's claim pays out only when the client pays before full funding, or when the advance push failed.
- Rounding dust goes to the last funder to claim.
- Funding closes after `dueDate`.
- The final slice may be below the 0.01 USDC minimum.
- The client can still pay after `Defaulted`.
- Known griefing risk: someone fills the 10 funder slots with 0.01 USDC contributions. Mitigation: the freelancer cancels and re-issues the invoice.

Open item for the mainnet build: compile with the same settings as Studio (solc 0.8.28, optimizer 200 runs, evm `cancun`) so the Hardhat-deployed bytecode matches Studio's build.

**GATE 1: met.**

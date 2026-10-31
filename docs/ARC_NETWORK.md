# Arc network facts (verified 2026-10-31)

Every value below was checked against the official Arc docs **and** against the live chain.

## Mainnet

| Field | Value | Source | Live check |
|---|---|---|---|
| Chain ID | `5042` (`0x13b2`) | docs.arc.io/arc/references/connect-to-arc.md | `eth_chainId` on the RPC returned `0x13b2` |
| RPC | `https://rpc.mainnet.arc.io` | connect-to-arc.md ("Primary") | Answers JSON-RPC |
| Explorer | `https://explorer.arc.io` | connect-to-arc.md | |
| USDC (ERC-20 interface) | `0x3600000000000000000000000000000000000000` | docs.arc.io/arc/references/contract-addresses.md | `decimals()` = 6, `symbol()` = "USDC" |
| Gas price (at check time) | ~20.03 gwei | | `eth_gasPrice` = `0x4a9ea8d11` |

Testnet: chain ID `5042002`, RPC `https://rpc.testnet.arc.io`, explorer `https://explorer.testnet.arc.io`. USDC is at the same `0x3600…0000` address.

## USDC decimals: one balance, two views

- USDC is Arc's **native gas token**. The native balance and the ERC-20 at `0x3600…0000` are the **same funds**, not two assets.
- **Native view: 18 decimals.** Used only for gas and `msg.value`. Wallets show this balance.
- **ERC-20 view: 6 decimals.** Used for `balanceOf`, `transfer`, `transferFrom` and `approve`.
- The two views differ by 10^12: 1 USDC = `1e6` ERC-20 units = `1e18` native units.
- `balanceOf` truncates sub-micro-USDC fractions. A zero `balanceOf` does not mean the native balance is zero.

**For Arcfloat:** every amount in the contract and the app is in **6-decimal ERC-20 units** (2.00 USDC = `2000000`). The contract must not be payable and must never touch `msg.value`. Gas is paid in native 18-decimal USDC, and the app should never add the native and ERC-20 balances together.

## Arc behaviors that affect us

- **Minimum `maxFeePerGas` is 20 gwei.** Lower transactions are silently dropped, with no error and no receipt. The Hardhat config must set fees at or above 20 gwei.
- **Blocklisted addresses:** a transfer to or from one reverts, and still consumes gas. This is why claims must be pull-based, as the spec already requires.
- **Value transfers to `address(0)` revert.**
- **A contract's USDC is held as its native balance.** `SELFDESTRUCT` can force native value into any contract, so the invariant to test is `balanceOf(contract) >= outstanding obligations`, not strict equality.
- **Block timestamps are non-decreasing, not strictly increasing.** This matters for `dueDate` comparisons only at second granularity.
- **Local simulators** (plain anvil or Hardhat network) run a standard EVM. They don't reproduce Arc behavior or the USDC predeploy. Tests there use a mock ERC-20, so the testnet run in Phase 2 is the real check.
- **Finality is instant**, so one confirmation is enough.

## Deploy tooling

The human deploys to mainnet with **Hardhat via npm** (Windows), using their own key from `.env`, which Claude never reads. The docs also recommend Arc Foundry (`arc-forge`), but we're not using it, at the human's choice.

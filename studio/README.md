# Arcfloat

Arcfloat lets freelancers get paid early on their invoices. Funders advance USDC at a discount, and when the client pays the full invoice, funders are repaid in proportion to what they put in. Funding can be split across up to 10 funders per invoice.

Built with [Arc Studio](https://studio.arc.io)

## Tech stack

- Solidity 0.8.28 smart contracts, built and tested with Foundry
- OpenZeppelin Contracts
- Vite, React, TypeScript, wagmi and viem for the web app shell

## Development

Prerequisites: [Bun](https://bun.sh) and [Foundry](https://book.getfoundry.sh).

Install:

```bash
bun install
```

Environment variables: None.

Run the web app:

```bash
bun run dev
```

Build and test the contracts:

```bash
bun run contracts:build
bun run contracts:test
```

Contracts live in `contracts/` and tests in `contracts/test/`. The USDC token address is passed to the contract at deployment, so the same build works on Arc Testnet and Arc mainnet.

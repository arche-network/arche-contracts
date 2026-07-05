# Arche Contracts - Phase 1

The core smart contracts for the Arche AI Agent Layer 2.

## Overview

Phase 1 delivers 5 core contracts that establish the on-chain economy for AI agents:

| Contract | Purpose |
|----------|---------|
| `ArcheTreasury.sol` | Ecosystem treasury (receives 50% of Agent Runtime Tax) |
| `AgentRegistry.sol` | KYA identity + staking + reputation |
| `AgentTax.sol` | 2.5% Agent Runtime Tax with dual-deflation |
| `ServicePayment.sol` | User → Agent payments with automatic tax + splits |
| `RevenueShare.sol` | L1/L2/L3 referral commissions (10%/6%/4%) |

**Gas Token**: Native `$ARCHE` (configured at chain launch via Conduit).
On Sepolia during first deployment, `msg.value` is Sepolia ETH; the same code works on Arche Testnet where it becomes native `$ARCHE`.

---

## Prerequisites

### 1. Foundry (fastest Solidity toolchain, 2026 standard)

```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.zshenv  # or ~/.zshrc
foundryup
```

Verify:
```bash
forge --version
```

### 2. RPC endpoint

Sign up for a free tier:
- Alchemy: https://alchemy.com/
- Or use public RPC (rate-limited)

For Sepolia testnet:
```bash
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
```

### 3. Deployment private key

⚠️ **Never** use your main wallet. Generate a fresh one:
```bash
cast wallet new-mnemonic
```
Save the mnemonic securely (1Password recommended, not iCloud).

Export the private key:
```bash
export PRIVATE_KEY=0x...
```

Get testnet ETH from a faucet:
- https://sepoliafaucet.com/
- https://cloud.google.com/application/web3/faucet

---

## Local Development

### Install dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
```

### Build

```bash
forge build
```

### Test (must be 100% green before deploying)

```bash
forge test -vv
```

Expected output:
```
Running 11 tests for test/ArcheE2E.t.sol:ArcheE2ETest
[PASS] testRegisterAgent() (gas: XXX)
[PASS] testE2E_PaymentWithTaxNoReferrer() (gas: XXX)
[PASS] testE2E_PaymentWithReferrers() (gas: XXX)
[PASS] testFuzz_TaxAlwaysBalanced(uint256) (runs: 256)
...
Test result: ok. 11 passed; 0 failed
```

### Test coverage

```bash
forge coverage
```

---

## Deployment

### 🟢 Live Deployments

**Ethereum Sepolia** (testnet, deployed 2026-07-05):

| Contract | Address |
|----------|---------|
| ArcheTreasury | [`0x43eD1577E2866f16314115C5813d11De86c316C4`](https://sepolia.etherscan.io/address/0x43eD1577E2866f16314115C5813d11De86c316C4) |
| AgentRegistry | [`0x04cfa2D9A5aff4D9d23a9576C943548709Ed31BF`](https://sepolia.etherscan.io/address/0x04cfa2D9A5aff4D9d23a9576C943548709Ed31BF) |
| AgentTax | [`0xaC8028A66CcC5E6e254782921CB55B72eFC160F5`](https://sepolia.etherscan.io/address/0xaC8028A66CcC5E6e254782921CB55B72eFC160F5) |
| ServicePayment | [`0x43cA25eb1d150674d1CA1ebEF3851D9D138E1bF0`](https://sepolia.etherscan.io/address/0x43cA25eb1d150674d1CA1ebEF3851D9D138E1bF0) |
| RevenueShare | [`0xA7b19E9719DfAba338eFc1d1E9525538629D6998`](https://sepolia.etherscan.io/address/0xA7b19E9719DfAba338eFc1d1E9525538629D6998) |

All cross-contract wiring verified on-chain. `$ARCHE` native-gas deployment on Arche Testnet coming next.


### Sepolia (dry run, first target)

```bash
forge script script/DeployArche.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

Output will show the 5 contract addresses. Save them.

### Arche Testnet (via Conduit)

Same command, different RPC:

```bash
export ARCHE_TESTNET_RPC_URL="https://arche-testnet.conduit.xyz/rpc"

forge script script/DeployArche.s.sol \
    --rpc-url $ARCHE_TESTNET_RPC_URL \
    --broadcast
```

---

## Contract Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                          User (Bob)                           │
│         calls payAgent(agentId, referrers, requestId)         │
│                    with msg.value = payment                   │
└─────────────────────────────┬────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│                       ServicePayment                          │
│  1. Verify agent is active                                   │
│  2. Compute tax rate (via AgentTax based on payer lockup)    │
│  3. Send tax portion to AgentTax                             │
│  4. Send referral budget to RevenueShare                     │
│  5. Send remainder to agent owner                            │
│  6. Update reputation                                        │
└──────────┬──────────────┬──────────────┬─────────────────────┘
           │              │              │
           ▼              ▼              ▼
  ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐
  │  AgentTax    │ │RevenueShare  │ │ Agent Owner      │
  │ 50% burn     │ │ 10%/6%/4%    │ │ (Alice)          │
  │ 50% treasury │ │ L1/L2/L3     │ │                  │
  └──────┬───────┘ └──────────────┘ └──────────────────┘
         │
         ▼
  ┌──────────────┐
  │ArcheTreasury │
  │ (grants,     │
  │  rewards)    │
  └──────────────┘
```

---

## Payment Flow Example

Bob pays Alice's agent 100 $ARCHE:

- **Tax**: 2.5% = 2.5 $ARCHE
  - 1.25 $ARCHE → burn address (permanent deflation)
  - 1.25 $ARCHE → ArcheTreasury (ecosystem grants)
- **Referrals** (if provided):
  - 10% (10 $ARCHE) → L1 referrer
  - 6% (6 $ARCHE) → L2 referrer
  - 4% (4 $ARCHE) → L3 referrer
- **Agent net**: 100 - 2.5 - 20 = 77.5 $ARCHE → Alice
- **Reputation**: +1 call, +77 rep points → Alice's agent

If Bob locks 10,000+ $ARCHE in ServicePayment, his tax drops from 2.5% → 1.5%.

---

## Security Notes for Phase 1

**In scope**:
- Reentrancy safety on all payable functions ✓ (checks-effects-interactions)
- Integer overflow ✓ (Solidity 0.8.x built-in)
- Access control ✓ (admin, owner modifiers)
- Two-step ownership transfer ✓

**Out of scope for Phase 1** (added in Phase 2):
- Slashing malicious agents (Guardrail Nodes)
- Time-locked lock-ups (30/90/180 day tiers)
- TEE attestation verification (Phala dstack)
- ERC-6551 Token-Bound Accounts
- Multi-sig treasury governance
- Formal verification (planned with Prof. Veneris)

---

## Roadmap

- [x] Phase 1: Core payment + registry (Sepolia + Arche Testnet)
- [ ] Phase 2: TEE integration + slashing + time-lock
- [ ] Phase 3: ERC-6551 TBA + Agent Store + intent routing
- [ ] Phase 4: Mainnet + TGE + DAO governance

---

## License

MIT © Arche Foundation

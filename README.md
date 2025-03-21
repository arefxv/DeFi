# DSCEngine - Decentralized Stablecoin System

## Overview

**DSCEngine**    is a Solidity-based decentralized stablecoin system designed to maintain a 1:1 peg with the U.S. dollar using exogenous collateral. This contract implements a minimalistic yet robust stablecoin model with the following features:

* **Dollar Pegged**: Maintains $1 peg per token

* **Exogenous Collateral**: Uses external assets like WETH and WBTC as collateral.

* **Algorithmically Stable**: Ensures overcollateralization to preserve stability.

Inspired by MakerDAO's DAI but simplified to remove governance, fees, and additional complexities, DSCEngine provides a permissionless platform for decentralized finance (DeFi).

---

## Key Features

* **Collateral Deposits & Redemptions**: Users can deposit collateral, mint stablecoins, redeem collateral, and burn stablecoins.

* **Liquidations**: Implements liquidation mechanisms to maintain system health and ensure overcollateralization.

* **Health Factor Monitoring**: Tracks and enforces minimum health factors to prevent undercollateralization.

* **Reentrancy Protection**: Leverages OpenZeppelin's `ReentrancyGuard` to secure against reentrancy attacks.

* **Price Feeds Integration**: Uses Chainlink price oracles for accurate asset valuation.
---


## Getting Started

### Prerequisites

* **Foundry** (Smart contract development framework)

* **OpenZeppelin Contracts** (Security libraries)

* **Chainlink Price Feeds** (Oracle integration)

### Installation

1. Clone the repository:

```
git clone https://github.com/arefxv/DSCEngine.git
cd DSCEngine
```

2. Install dependencies:

```
forge install
```

3. Compile contracts:

```
forge build
```

4. Run tests:
```
forge test
```

---

## Usage

### Deploy Contract

1. Configure your deployment parameters in `script/Deploy.s.sol.`

2. Deploy using Foundry:
```
forge script script/Deploy.s.sol --rpc-url <YOUR_RPC_URL> --private-key <YOUR_PRIVATE_KEY> --broadcast
```

### Contract Functions

* Deposit Collateral:
```
depositCollateral(address tokenCollateral, uint256 amount)
```

Deposits collateral tokens into the contract.

* Mint Stablecoins:

```
mintDsc(uint256 amountToMint)
```

Mints decentralized stablecoins based on the deposited collateral.

* Redeem Collateral:
```
redeemCollateral(address tokenCollateral, uint256 amount)
```

Withdraws collateral while ensuring sufficient health factor.

* Liquidate Under-Collateralized Accounts:
```
liquidate(address collateral, address user, uint256 debtToCover)
```
Allows third parties to liquidate unhealthy positions for a reward.

---

## Security Features

1. **Reentrancy Protection:** Utilizes OpenZeppelin's ReentrancyGuard to prevent reentrancy attacks.

2. **Health Factor Monitoring**: Enforces minimum collateral ratios to safeguard against insolvency.

3. **CEI Pattern**: Implements "Checks-Effects-Interactions" to ensure secure execution of functions.
___

# Author

## ArefXV

### Socials : [ArefXV](https://linktr.ee/arefxv)# DeFi

# 1inch Security Dashboard 🛡️

## 🧭 Overview

**1inch Security Dashboard** — a monitoring and analytics module built on top of 1inch Router that enables real-time tracking of swaps, detection of suspicious transactions, token security assessment, and warnings about potential risks.

This is not a competing project with 1inch, but a **security overlay** that complements the aggregator's infrastructure with analysis and monitoring tools available to both developers and DeFi users.

---

## 🚀 Why This Is Needed

While **Fusion+** and 1inch Router provide secure execution mechanics (MEV protection, order fragmentation, and private swaps), they **do not perform post-factum audits**, do not track **user/contract actions**, do not **analyze activity history**, and **do not visualize risks**.

**1inch Security Dashboard solves this.**

---

## 🎯 Use-cases

- DAO monitors suspicious activities through interface or API
- Developer integrates real-time protection into their decentralized interface
- User receives analytics of their swaps and warnings about potential threats (fraud tokens, sharp price deviations, proxy attacks)
- Security teams use the tool as an additional layer of monitoring for contracts and tokens

---

## 🧩 Architecture

### 📘 Contracts

| Contract                   | Purpose                                                                                                                                                                                                                                                                       |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **SwapAuditor**            | Central point of swap analysis logic. Receives input data and performs validation through modules (including TWAP).                                                                                                                                                           |
| **SwapProxy**              | Proxy over 1inch Router. Executes calls through a secure wrapper with logging, analytics, and hooks.                                                                                                                                                                          |
| **TwapSwap**               | TWAP (Time-Weighted Average Price) module that enables users to create and execute orders split into intervals. Provides price sanity-check layer for SwapAuditor by comparing swap prices with fair market rates. Includes executor fee system and interval-based execution. |
| **TokenRiskOracle (opt.)** | Processes token suspicion flags (e.g., blacklist, honeypot, scam). In the future — integration with Chainlink External Adapter.                                                                                                                                               |

### 🔌 Integrations

| External Resource    | Purpose                                |
| -------------------- | -------------------------------------- |
| **1inch Router**     | Base swap mechanism                    |
| **Chainlink Oracle** | TWAP and sanity-check (price fairness) |
| **Custom DB/API**    | For storing and visualizing history    |

---

## 📡 Core Functions

### 🔍 SwapAuditor

- Tracks incoming swap calls (through SwapProxy)
- Checks:
  - Price plausibility (through TWAP module)
  - Presence of suspicious tokens
  - Flashloan-like patterns
  - Abnormal volumes
- Makes logic extensible for future modules (e.g., approvals, anti-reentrancy, etc.)

### 🧭 TWAP Module (TwapSwap)

- Enables users to create TWAP orders, splitting large swaps into smaller intervals to reduce slippage and market impact
- Provides reference price for SwapAuditor to validate swap plausibility and detect abnormal price deviations
- Integrates with external oracles or onchain TWAP sources (e.g., Uniswap V3) to compare swap prices with fair market rates
- Includes executor fee system and interval-based execution mechanism
- Designed for extensibility and integration with other DeFi analytics and security modules

### 🔗 SwapProxy

- Wrapper over calls to 1inch Router
- Allows intercepting and analyzing data before and after swaps
- Provides tracing through events

---

## 📊 Visualization

Within the MVP, a minimal web interface panel is implemented that displays:

- Swap history (tx hash, address, tokens, amount)
- Labels: high-risk token, slippage warning, flash-pattern detected
- Activity charts and temporal spikes
- Potential integration with Telegram/Webhook notifications

---

## 🧠 Why This Works

Current solutions in the ecosystem (including 1inch, Uniswap, Paraswap) focus on **execution optimization** but not on **risk decomposition** and **action auditing** of users or contracts.

**Security Dashboard** fills this niche:

- Provides **objective feedback** in DeFi where "unclear" things are expensive
- Creates an **analytics framework** extensible to any DEX infrastructure
- Can be used as internal tooling in large protocols or DAOs

---

## 🔧 Development Opportunities

- Support for other DEXs (Uniswap, Balancer, Curve)
- Extended oracle system (API3, DIA)
- User wallet protection mode — integration with custom wallets
- Token reputation scoring system
- Visual DeFi Tracer (from swap to lending, farming, etc.)

---

## 📣 Supported Networks

- Ethereum
- Arbitrum (within hackathon scope)
- Potentially: Base, Polygon, Optimism

---

## 🤝 Acknowledgments

The project was developed as part of **ETHGlobal Unite Hackathon** with the goal of enhancing transparency and security in DeFi through modular monitoring tools.

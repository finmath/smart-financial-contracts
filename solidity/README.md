# Solidity packages

All contract projects are grouped here. Each buildable package keeps its own
dependencies, compiler configuration, tests and generated output.

| Directory | Contents | Toolchain |
| --- | --- | --- |
| [`framework/`](framework/README.md) | Smart Product Framework, ERC-8100 resources, settlement helpers and the fixed-rate bond example | Node.js 22.13+, Hardhat 3 |
| [`derivatives/`](derivatives/doc/README.md) | Derivative contracts and delivery-versus-payment implementations | Node.js 16, Hardhat 2 |
| [`examples/erc8100-products/`](examples/erc8100-products/README.md) | Original SimpleBond and InterestRateSwap demonstrations | Node.js 22+, Foundry |
| [`examples/fx-spot-trade/`](examples/fx-spot-trade/README.md) | FX Spot Trade demonstration | Foundry |
| [`ercs/erc-6123/`](ercs/erc-6123/README.md) | Maintained ERC-6123 interfaces, specification and reference implementations | Node.js 22, Hardhat 2 |
| `ercs/erc-7573/` | Public ERC-7573 reference snapshot | Reference material |
| [`origins/`](origins/README.md) | Preserved original sources, resources and license notices | Reference material |

## Build and test

Run these commands from the repository root, with the runtime required by the
selected package:

```sh
# Smart Product Framework and fixed-rate bond
(cd solidity/framework && npm ci && npm test)

# ERC-6123 reference implementations
(cd solidity/ercs/erc-6123 && npm ci && npm test)

# Derivative contracts (Node.js 16)
(cd solidity/derivatives && npm ci --ignore-scripts && npm test)

# Original product demonstrations
(cd solidity/examples/erc8100-products && npm ci && forge test)

# FX Spot Trade
(cd solidity/examples/fx-spot-trade && forge test)
```

There is no shared npm installation at `solidity/`. The framework and derivative
packages use different Hardhat and Ethers versions, and the original product
examples use a different OpenZeppelin version. Their sources are compiled within
their own package boundaries. The fixed-rate bond example belongs to the framework
package because it uses the maintained framework interfaces and linked libraries.

The framework's fixed-rate bond and the FX demo use the maintained ERC-6123
trade interface in `ercs/erc-6123/`. The legacy derivative package retains its own
interface and compiler configuration; it is tested separately.

The ERC-7573 snapshot and preserved source references are outside these builds.
The Java valuation service and frontend remain at the repository root.

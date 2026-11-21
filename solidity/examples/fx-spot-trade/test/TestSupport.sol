// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {FxSpotTrade} from "../contracts/FxSpotTrade.sol";
import {IERC20RouterToken} from "../contracts/ERC20PvPSettlementRouter.sol";

/// @dev The suite needs only these Foundry cheatcodes; no external test library is required.
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

interface ITransferHook {
    function onTransfer() external;
}

/// @dev Exact-transfer fixture that also models common ERC-20 return conventions and failures.
contract ReturnToken is IERC20RouterToken {
    enum Behavior {
        True,
        False,
        Revert,
        NoData,
        ShortData
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Behavior public behavior;
    ITransferHook public hook;

    function setBehavior(Behavior value) external {
        behavior = value;
    }

    function setHook(ITransferHook value) external {
        hook = value;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (address(hook) != address(0)) hook.onTransfer();
        if (behavior == Behavior.Revert) revert("token failure");
        if (behavior == Behavior.False) return false;
        if (behavior == Behavior.NoData) {
            assembly {
                return(0, 0)
            }
        }
        if (behavior == Behavior.ShortData) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        return true;
    }
}

/// @dev A genuine counterparty reenters from a token callback while its confirmation is running.
contract ReentrantCounterparty is ITransferHook {
    FxSpotTrade private trade;
    address private inceptor;
    bool public attempted;
    bytes4 public reentryError;
    bytes4 public inceptionReentryError;
    bytes4 public cancellationReentryError;

    function approve(ReturnToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function confirm(FxSpotTrade trade_, address inceptor_) external {
        trade = trade_;
        inceptor = inceptor_;
        trade.confirmTrade("1", inceptor, address(this), "terms", 100, -200, "settlement");
    }

    function onTransfer() external {
        attempted = true;
        (bool success, bytes memory errorData) = address(trade)
            .call(
                abi.encodeCall(
                    FxSpotTrade.confirmTrade,
                    ("1", inceptor, address(this), "terms", 100, -200, "settlement")
                )
            );
        require(!success, "reentrant confirmation succeeded");
        require(errorData.length >= 4, "missing reentry error");
        reentryError = bytes4(errorData);

        // The counterparty is a legitimate inceptor for a future trade. Even
        // though trade 1 is already marked Settled, opening trade 2 must wait
        // until BOTH token legs and terminal events have completed.
        (success, errorData) = address(trade)
            .call(
                abi.encodeCall(
                    FxSpotTrade.inceptTrade,
                    (address(this), inceptor, "next terms", 100, -200, "settlement")
                )
            );
        require(!success && errorData.length >= 4, "reentrant inception succeeded");
        inceptionReentryError = bytes4(errorData);

        (success, errorData) = address(trade)
            .call(
                abi.encodeCall(
                    FxSpotTrade.cancelTrade,
                    ("1", inceptor, address(this), "terms", 100, -200, "settlement")
                )
            );
        require(!success && errorData.length >= 4, "reentrant cancellation succeeded");
        cancellationReentryError = bytes4(errorData);
    }
}

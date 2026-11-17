// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 interface used by the settlement router.
interface IERC20RouterToken {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @notice Synchronous settlement and cancellation interface called by factory-created FX swaps.
interface IAtomicSwapSettlement {
    /// @notice Consumes one trade's unused authorization on the calling swap.
    function cancelAtomicSwap(string calldata tradeId) external;

    /// @notice Completes both token legs before returning, or reverts the entire settlement.
    function settleAtomicSwap(
        string calldata tradeId,
        IERC20RouterToken baseToken,
        IERC20RouterToken quoteToken,
        address inceptor,
        address counterparty,
        int256 position,
        int256 paymentAmount
    ) external;
}

/**
 * @title ERC-20 Atomic Swap Settlement Router
 * @notice Common ERC-20 spender for all swaps created by one factory.
 * @dev Token holders approve this router once. Factory registration persists across
 *      trades, while each (swap, trade ID) authorization is consumed at most once.
 *      The trusted swap enforces unique inception IDs, consent and matching terms;
 *      its fixed configuration is the source of the tokens and eligible parties.
 *      Supported tokens transfer exactly the requested amount on success.
 *      Fee-on-transfer and rebasing tokens are outside this example's scope;
 *      the router does not verify balance deltas.
 */
contract ERC20AtomicSwapSettlementRouter is IAtomicSwapSettlement {
    error InvalidFactory();
    error InvalidSwap();
    error NotFactory();
    error UnregisteredSwap();
    error InvalidTradeId();
    error TradeAlreadyConsumed();
    error TransferFromFailed(address token);

    address public immutable factory;
    mapping(address swap => bool registered) public registeredSwap;
    /// @notice True after settlement or cancellation; ID key is keccak256(bytes(tradeId)).
    mapping(address swap => mapping(bytes32 idHash => bool consumed)) public consumedTrade;

    /**
     * @notice Creates a settlement router controlled by one immutable factory.
     * @param factory_ Factory allowed to register newly created swaps.
     */
    constructor(address factory_) {
        if (factory_ == address(0)) revert InvalidFactory();
        factory = factory_;
    }

    /**
     * @notice Permanently registers one factory-created reusable swap.
     * @dev The factory deploys the exact trusted swap implementation and calls this method in the same transaction.
     * @param swap Newly deployed swap contract.
     */
    function registerSwap(address swap) external {
        if (msg.sender != factory) revert NotFactory();
        if (swap.code.length == 0 || registeredSwap[swap]) revert InvalidSwap();

        registeredSwap[swap] = true;
    }

    /**
     * @notice Consumes an identified trade's authorization without moving tokens.
     * @dev Only a registered swap can cancel its own trade. The trusted swap checks
     *      the inceptor, pending trade ID and matching terms before calling.
     *      Registration and ERC-20 allowances remain available for later trades.
     */
    function cancelAtomicSwap(string calldata tradeId) external override {
        _consumeTrade(tradeId);
    }

    /**
     * @notice Transfers both token legs for one identified trade on a registered swap.
     * @dev `msg.sender` must be a swap registered by the immutable factory. Its
     *      trade authorization is consumed before either external token call. The
     *      trusted swap also prevents re-entry across its trades during settlement.
     *      Any failure reverts both transfers and restores that trade's authorization
     *      atomically; registration is never consumed.
     *
     *      Signed amounts are viewed from `inceptor`: positive means receive the
     *      token and negative means deliver it. The trusted swap has already
     *      validated that both legs are nonzero, opposite in sign, and not
     *      `type(int256).min`.
     * @param tradeId Nonempty lifetime-unique trade identifier within the calling swap.
     * @param baseToken ERC-20 token represented by `position`.
     * @param quoteToken ERC-20 token represented by `paymentAmount`.
     * @param inceptor Party from whose perspective both amounts are signed.
     * @param counterparty Opposite fixed party.
     * @param position Signed base-token amount.
     * @param paymentAmount Signed quote-token amount.
     */
    function settleAtomicSwap(
        string calldata tradeId,
        IERC20RouterToken baseToken,
        IERC20RouterToken quoteToken,
        address inceptor,
        address counterparty,
        int256 position,
        int256 paymentAmount
    ) external override {
        // Consume this ID before calling either ERC-20 contract.
        _consumeTrade(tradeId);

        _move(baseToken, inceptor, counterparty, position);
        _move(quoteToken, inceptor, counterparty, paymentAmount);
    }

    function _consumeTrade(string calldata tradeId) private {
        if (!registeredSwap[msg.sender]) revert UnregisteredSwap();
        if (bytes(tradeId).length == 0) revert InvalidTradeId();
        bytes32 idHash = keccak256(bytes(tradeId));
        if (consumedTrade[msg.sender][idHash]) revert TradeAlreadyConsumed();
        consumedTrade[msg.sender][idHash] = true;
    }

    /**
     * @notice Executes one signed token leg from `viewParty`'s perspective.
     * @param token ERC-20 token of the leg.
     * @param viewParty Party from whose perspective `signedAmount` is stated.
     * @param otherParty Opposite party.
     * @param signedAmount Positive to receive, negative to deliver.
     */
    function _move(
        IERC20RouterToken token,
        address viewParty,
        address otherParty,
        int256 signedAmount
    ) private {
        if (signedAmount > 0) {
            // This branch proves the value is positive and therefore representable as uint256.
            // forge-lint: disable-next-line(unsafe-typecast)
            _safeTransferFrom(token, otherParty, viewParty, uint256(signedAmount));
        } else {
            // The trusted swap rejects zero and type(int256).min, so negation is positive and safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            _safeTransferFrom(token, viewParty, otherParty, uint256(-signedAmount));
        }
    }

    /**
     * @notice Calls `transferFrom`, accepting true or no return data and rejecting false or a revert.
     * @param token ERC-20 token to call.
     * @param from Token owner that approved this router.
     * @param to Token recipient.
     * @param value Amount in the token's smallest unit.
     */
    function _safeTransferFrom(IERC20RouterToken token, address from, address to, uint256 value)
        private
    {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20RouterToken.transferFrom, (from, to, value)));

        if (!success || (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))) {
            revert TransferFromFailed(address(token));
        }
    }
}

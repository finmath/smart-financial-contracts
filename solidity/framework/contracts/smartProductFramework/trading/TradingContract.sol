// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IClientRegistry} from "../clientRegistry/IClientRegistry.sol";
import {IProductDefinitionRegistry} from "../productDefinitionRegistry/IProductDefinitionRegistry.sol";

interface ITradingContractDirectory {
    function tradingContractOf(address client) external view returns (address);
    function clientOf(address tradingContract) external view returns (address);
}

/// @notice One client's address for sending and receiving non-binding product requests.
/// @dev The recipient stores the request. Issuance registers a product; both parties agree on its terms in the product.
contract TradingContract is ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    enum TradeRequestStatus { Unknown, Active, Fulfilled, Withdrawn, Rejected, Expired }

    struct TradeRequest {
        TradeRequestStatus status;
        uint64 createdAt;
        address requester;
        bytes32 productDefinitionId;
        uint256 productDefinitionVersion;
        bytes productPayload;
        address product;
    }

    address public immutable client;
    ITradingContractDirectory public immutable tradingContractFactory;
    IProductDefinitionRegistry public immutable productRegistry;
    IClientRegistry public immutable clientRegistry;
    mapping(address operator => bool) public isOperator;

    uint256 private _nonce;
    mapping(bytes32 tradeRequestId => TradeRequest) private _requests;
    mapping(bytes32 definitionId => mapping(uint256 version => EnumerableSet.Bytes32Set)) private _activeRequests;

    event OperatorSet(address indexed operator, bool allowed);
    event TradeRequested(bytes32 indexed productDefinitionId, address indexed requester, bytes32 indexed tradeRequestId);
    event TradeRequestWithdrawn(bytes32 indexed tradeRequestId);
    event TradeRequestRejected(bytes32 indexed tradeRequestId);
    event TradeRequestFulfilled(bytes32 indexed tradeRequestId, address indexed product);

    error NotClient(address caller);
    error UnknownTradingContract(address caller);
    error ClientNotEligible(address client, bytes32 productDefinitionId);
    error NotRequester(address caller);
    error SelfRequest();
    error WrongDefinitionVersion(uint256 expected, uint256 actual);
    error UnknownTradeRequest(bytes32 tradeRequestId);
    error InvalidTradeRequestStatus(bytes32 tradeRequestId, TradeRequestStatus status);
    error NoTradeRequests();
    error MismatchedRequest(bytes32 tradeRequestId);

    constructor(address client_, address productRegistry_, IClientRegistry clientRegistry_) {
        client = client_;
        productRegistry = IProductDefinitionRegistry(productRegistry_);
        clientRegistry = clientRegistry_;
        tradingContractFactory = ITradingContractDirectory(msg.sender);
    }

    modifier onlyTrader() {
        if (msg.sender != client && !isOperator[msg.sender]) revert NotClient(msg.sender);
        _;
    }

    /// @notice Authorize an application to manage trading requests and initiate product issuance for this client.
    function setOperator(address operator, bool allowed) external {
        if (msg.sender != client) revert NotClient(msg.sender);
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Send a request from this client's address to another participant's trading contract.
    function sendTradeRequest(
        address recipientDesk, bytes32 productDefinitionId, uint256 expectedVersion, bytes calldata productPayload
    ) external onlyTrader returns (bytes32 tradeRequestId) {
        return _recipient(recipientDesk).createTradeRequest(productDefinitionId, expectedVersion, productPayload);
    }

    /// @notice Receive a request directly from a participating client or from its canonical trading contract.
    function createTradeRequest(bytes32 productDefinitionId, uint256 expectedVersion, bytes calldata productPayload)
        external returns (bytes32 tradeRequestId)
    {
        address requester = _requester();
        if (requester == client) revert SelfRequest();
        _requireActiveDefinition(productDefinitionId, expectedVersion);
        _requireEligible(requester, productDefinitionId);
        _requireEligible(client, productDefinitionId);

        tradeRequestId = keccak256(abi.encode(block.chainid, address(this), ++_nonce));
        _requests[tradeRequestId] = TradeRequest({
            status: TradeRequestStatus.Active,
            createdAt: uint64(block.timestamp),
            requester: requester,
            productDefinitionId: productDefinitionId,
            productDefinitionVersion: expectedVersion,
            productPayload: productPayload,
            product: address(0)
        });
        _activeRequests[productDefinitionId][expectedVersion].add(tradeRequestId);
        emit TradeRequested(productDefinitionId, requester, tradeRequestId);
    }

    /// @notice Withdraw the client's outbound request through its own trading contract.
    function withdrawSentTradeRequest(address recipientDesk, bytes32 tradeRequestId) external onlyTrader {
        _recipient(recipientDesk).withdrawTradeRequest(tradeRequestId);
    }

    function withdrawTradeRequest(bytes32 tradeRequestId) external {
        TradeRequest storage request = _activeRequest(tradeRequestId);
        if (_requester() != request.requester) revert NotRequester(msg.sender);
        _close(tradeRequestId, request, TradeRequestStatus.Withdrawn);
        emit TradeRequestWithdrawn(tradeRequestId);
    }

    function rejectTradeRequest(bytes32 tradeRequestId) external onlyTrader {
        _close(tradeRequestId, _activeRequest(tradeRequestId), TradeRequestStatus.Rejected);
        emit TradeRequestRejected(tradeRequestId);
    }

    /// @notice Create a product for one or more requests of the same definition revision.
    /// @dev Fulfillment links each request to the deployed instance. The parties agree on an offer in the product.
    function issueProductForRequests(
        bytes32[] calldata tradeRequestIds, bytes calldata productPayload
    ) external onlyTrader nonReentrant returns (address product) {
        if (tradeRequestIds.length == 0) revert NoTradeRequests();
        TradeRequest storage first = _activeRequest(tradeRequestIds[0]);
        bytes32 definitionId = first.productDefinitionId;
        uint256 version = first.productDefinitionVersion;
        for (uint256 i; i < tradeRequestIds.length; ++i) {
            bytes32 id = tradeRequestIds[i];
            TradeRequest storage request = _requests[id];
            if (request.status != TradeRequestStatus.Active) revert InvalidTradeRequestStatus(id, request.status);
            if (request.productDefinitionId != definitionId || request.productDefinitionVersion != version) {
                revert MismatchedRequest(id);
            }
            _requireEligible(request.requester, definitionId);
            _close(id, request, TradeRequestStatus.Fulfilled);
        }
        product = productRegistry.issueProduct(definitionId, version, productPayload);
        for (uint256 i; i < tradeRequestIds.length; ++i) {
            bytes32 id = tradeRequestIds[i];
            _requests[id].product = product;
            emit TradeRequestFulfilled(id, product);
        }
    }

    /// @notice Create a new product directly, without preceding requests.
    function issueProduct(
        bytes32 productDefinitionId, uint256 expectedVersion, bytes calldata productPayload
    ) external onlyTrader nonReentrant returns (address product) {
        _requireActiveDefinition(productDefinitionId, expectedVersion);
        return productRegistry.issueProduct(productDefinitionId, expectedVersion, productPayload);
    }

    /// @notice Returns the original request, its effective status, and any product issued in response.
    /// @dev Open requests expire on retirement or a new definition version. Their original payload remains readable.
    function tradeRequestState(bytes32 tradeRequestId) external view returns (TradeRequest memory state) {
        TradeRequest storage request = _requests[tradeRequestId];
        if (request.status == TradeRequestStatus.Unknown) revert UnknownTradeRequest(tradeRequestId);
        state = request;
        state.status = _status(request);
    }

    /// @notice Active request ids for this recipient and the current definition revision.
    function getActiveTradeRequests(bytes32 productDefinitionId) external view returns (bytes32[] memory) {
        IProductDefinitionRegistry.ProductDefinitionState memory definition = productRegistry.productDefinitionState(productDefinitionId);
        if (!_isFulfillable(definition.status)) return new bytes32[](0);
        return _activeRequests[productDefinitionId][definition.version].values();
    }

    function _requester() private view returns (address) {
        address principal = tradingContractFactory.clientOf(msg.sender);
        if (principal != address(0)) return principal;
        if (tradingContractFactory.tradingContractOf(msg.sender) == address(0)) revert UnknownTradingContract(msg.sender);
        return msg.sender;
    }

    function _recipient(address desk) private view returns (TradingContract) {
        if (tradingContractFactory.clientOf(desk) == address(0)) revert UnknownTradingContract(desk);
        return TradingContract(desk);
    }

    function _requireEligible(address party, bytes32 definitionId) private view {
        if (!clientRegistry.isEligibleClient(party, definitionId)) revert ClientNotEligible(party, definitionId);
    }

    function _requireActiveDefinition(bytes32 definitionId, uint256 expectedVersion) private view {
        IProductDefinitionRegistry.ProductDefinitionState memory definition = productRegistry.productDefinitionState(definitionId);
        if (definition.status != IProductDefinitionRegistry.ProductDefinitionStatus.Active) {
            revert IProductDefinitionRegistry.ProductDefinitionNotActive(definitionId, definition.status);
        }
        if (definition.version != expectedVersion) revert WrongDefinitionVersion(expectedVersion, definition.version);
    }

    function _isFulfillable(IProductDefinitionRegistry.ProductDefinitionStatus status) private pure returns (bool) {
        return status == IProductDefinitionRegistry.ProductDefinitionStatus.Active
            || status == IProductDefinitionRegistry.ProductDefinitionStatus.Suspended;
    }

    function _status(TradeRequest storage request) private view returns (TradeRequestStatus) {
        if (request.status != TradeRequestStatus.Active) return request.status;
        IProductDefinitionRegistry.ProductDefinitionState memory definition = productRegistry.productDefinitionState(request.productDefinitionId);
        if (definition.version != request.productDefinitionVersion || !_isFulfillable(definition.status)) {
            return TradeRequestStatus.Expired;
        }
        return TradeRequestStatus.Active;
    }

    function _activeRequest(bytes32 id) private view returns (TradeRequest storage request) {
        request = _requests[id];
        if (request.status == TradeRequestStatus.Unknown) revert UnknownTradeRequest(id);
        TradeRequestStatus status = _status(request);
        if (status != TradeRequestStatus.Active) revert InvalidTradeRequestStatus(id, status);
    }

    function _close(bytes32 id, TradeRequest storage request, TradeRequestStatus status) private {
        request.status = status;
        _activeRequests[request.productDefinitionId][request.productDefinitionVersion].remove(id);
    }
}

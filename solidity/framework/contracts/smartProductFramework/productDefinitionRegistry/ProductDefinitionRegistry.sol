// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITextResource} from "../../erc8100/ITextResource.sol";
import {IXMLRepresentableStatePart, IRepresentableStateVersioned} from "../../erc8100/IRepresentableState.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {LibString} from "solady/src/utils/LibString.sol";

import {IProductDefinitionRegistry} from "./IProductDefinitionRegistry.sol";
import {IProductIndication} from "../productIndications/IProductIndication.sol";
import {IProductFactory} from "../productFactories/IProductFactory.sol";
import {TradingContractFactory} from "../trading/TradingContractFactory.sol";
import {IClientRegistry} from "../clientRegistry/IClientRegistry.sol";
import {CommonDeploymentParams, ProductDeploymentParams} from "../productFactories/ProductDeploymentTypes.sol";

/**
 * @title ProductDefinitionRegistry
 * @notice Registry for versioned product definitions, indication assignments and product issuance.
 *
 * @dev Each product definition anchors the exact factory and finalized text
 *      resources used for deployment. The registry validates the anchored
 *      components, manages lifecycle state, and deploys products directly
 *      through the selected factory.
 *
 *      Product definition ids are derived as:
 *
 *          keccak256(abi.encode(name, address(this)))
 *
 *      The corresponding state-part id is uint256(productDefinitionId).
 *
 * @author Raphael Prandtl
 */
contract ProductDefinitionRegistry is IProductDefinitionRegistry, IXMLRepresentableStatePart, IRepresentableStateVersioned, ReentrancyGuard {
    using Strings for uint256;
    using ERC165Checker for address;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Maximum number of entries returned by definition discovery pages.
    uint256 public constant MAX_DISCOVERY_PAGE_SIZE = 100;

    // ------------------------------ Custom Errors ------------------------------ */

    /// @notice Thrown when a state-part id does not represent a product definition.
    error UnknownPart(uint256 partId);

    /// @notice Thrown when a required hash is zero.
    error ZeroHash(string field);

    /// @notice Thrown when an address has no contract code.
    error EmptyContract(address contractAddress);

    /// @notice Thrown when a contract does not implement the expected interface.
    error InvalidInterface(address contractAddress);

    /// @notice Thrown when a factory is configured for another registry.
    error FactoryNotConfigured(address configuredRegistry);

    /// @notice Thrown when an external validation call fails.
    error ContractCallFailed(address contractAddress, string functionName);

    /// @notice Thrown when a text resource is not finalized.
    error ResourceNotFinalized(address resource);

    /// @notice Thrown when a text resource has an unexpected type.
    error InvalidResourceType(address resource, bytes32 expected, bytes32 actual);

    /// @notice Thrown when a factory does not accept an indication category.
    error UnsupportedIndicationCategory(address productIndication, bytes32 indicationCategory);

    /// @notice Thrown when an indication cannot be assigned in its current status.
    error InvalidIndicationStatus(address productIndication, IProductIndication.IndicationStatus status);

    /// @notice Thrown when a product definition has no product indication assigned.
    error MissingProductIndication(bytes32 productDefinitionId);

    /// @notice Thrown when a factory exposes an invalid specification.
    error InvalidProductFactory(address factory);

    /// @notice Thrown when the caller is not eligible for the product definition.
    error ClientNotEligible(address client, bytes32 productDefinitionId);

    /// @notice The caller must be the current owner of the client registry.
    error UnauthorizedRegistryOwner(address caller);

    /// @notice Issuance is restricted to trading contracts created for this registry.
    error UnrecognizedTradingContract(address caller);

    /// @notice The caller selected a different revision of the definition.
    error ProductDefinitionVersionMismatch(bytes32 productDefinitionId, uint256 expectedVersion, uint256 currentVersion);

    /// @notice Thrown when an operation requires an active or suspended product definition.
    error ProductDefinitionNotFulfillable(bytes32 productDefinitionId, ProductDefinitionStatus status);

    /// @notice Thrown when the product deployment by the external factory failed
    error ProductDeploymentFailed(address factory);

    /// @notice Thrown when the deployed product could not be verified
    error InvalidDeployedProduct(address factory, address product);

    // ------------------------------ Events ------------------------------ */

    /// @notice Emitted when a rendered product-definition state part changes.
    event StatePartUpdated(address indexed sender, address indexed stateContract, uint256 indexed partId, uint256 partVersion);

    /// @notice Emitted when a product definition's product indication is assigned or replaced.
    event ProductIndicationAssigned(bytes32 indexed productDefinitionId, address indexed productIndication, bytes32 indicationId);

    /// @notice Emitted when a product definition's indication is cleared.
    event ProductIndicationCleared(bytes32 indexed productDefinitionId);

    /// @notice Emitted when a product is issued.
    event ProductIssued(bytes32 indexed productDefinitionId, uint256 productDefinitionVersion, address indexed product);

    // ------------------------------ Storage ------------------------------ */

    /// @notice Monotonic version of all product-definition XML parts.
    /// @dev Separate from the component version used to bind trade requests. Lifecycle and
    ///      indication-assignment changes also advance this checked counter. XML embeds only
    ///      stored definition data and references to finalized, immutable ITextResource content;
    ///      indication payloads are rendered by the indication contract.
    uint256 public override stateVersion;

    /// @dev partId is not stored because it is derivable from the key.
    struct ProductDefinitionStorage {
        ProductDefinitionStatus status;
        uint64 publishedAt;
        uint64 updatedAt;
        string name;
        uint256 version;
        ProductDefinition productDefinition;
    }

    /// @notice Indication assigned to a product definition.
    struct ProductIndicationAssignment {
        address productIndication;
        bytes32 indicationId;
        uint256 partId;
    }

    /// @notice Client registry used for eligibility checks.
    address public immutable override clientRegistryAddress;

    /// @inheritdoc IProductDefinitionRegistry
    address public immutable override tradingContractFactory;

    /// @notice Maps a product definition id to its storage.
    mapping(bytes32 => ProductDefinitionStorage) internal _productDefinitionsById;

    /// @notice Every definition in first-publication order. Entries are never removed.
    EnumerableSet.Bytes32Set private _productDefinitionIds;

    /// @dev Keyed by the same productDefinitionId as _productDefinitionsById.
    mapping(bytes32 => ProductIndicationAssignment) internal _indicationsByDefinitionId;

    /// @notice Verifies a product is issued by this registry.
    mapping(address => bool) private _isRegisteredProduct;

    // ------------------------------ Administration ------------------------------ */

    constructor(address clientRegistryAddress_) {
        _validateContractAddress(clientRegistryAddress_, "clientRegistry");
        if (Ownable(clientRegistryAddress_).owner() == address(0)) revert ZeroAddress("clientRegistry.owner");
        clientRegistryAddress = clientRegistryAddress_;
        tradingContractFactory = address(new TradingContractFactory(address(this), clientRegistryAddress_));
    }

    /// @inheritdoc IProductDefinitionRegistry
    function owner() public view override returns (address) {
        return Ownable(clientRegistryAddress).owner();
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert UnauthorizedRegistryOwner(msg.sender);
        _;
    }

    // ------------------------------ Product Definition Publication and Lifecycle Management ------------------------------ */

    function publishProductDefinition(ProductDefinitionPublicationParams calldata params) external override onlyOwner returns (bytes32 productDefinitionId) {
        _validateProductDefinitionPublicationParams(params);

        productDefinitionId = _productDefinitionId(params.name);
        ProductDefinitionStorage storage definitionStorage = _productDefinitionsById[productDefinitionId];
        if (definitionStorage.status != ProductDefinitionStatus.Unknown) {
            revert ProductDefinitionAlreadyExists(productDefinitionId);
        }

        definitionStorage.status = ProductDefinitionStatus.Active;
        definitionStorage.name = params.name;
        definitionStorage.publishedAt = uint64(block.timestamp);
        definitionStorage.productDefinition = params.productDefinition;

        _productDefinitionIds.add(productDefinitionId);
        _touchProductDefinition(definitionStorage);

        emit ProductDefinitionPublished(productDefinitionId, params.productDefinition.productFactory, params.productDefinition.productTermsTemplate, params.productDefinition.productDocumentationTemplate);
        emit ProductDefinitionStatusChanged(productDefinitionId, ProductDefinitionStatus.Unknown, ProductDefinitionStatus.Active);
        emit StatePartUpdated(msg.sender, address(this), _partIdFromProductDefinitionId(productDefinitionId), definitionStorage.version);
    }

    function updateProductDefinition(bytes32 productDefinitionId, ProductDefinition calldata productDefinition) external override onlyOwner {
        _validateProductDefinition(productDefinition);

        ProductDefinitionStorage storage definitionStorage = _existingProductDefinition(productDefinitionId);
        _ensureProductDefinitionWritable(productDefinitionId, definitionStorage.status);
        // Revalidate existing indication assignment if factory is updated
        ProductIndicationAssignment storage assignment = _indicationsByDefinitionId[productDefinitionId];
        if (assignment.productIndication != address(0) && definitionStorage.productDefinition.productFactory != productDefinition.productFactory) {
            _validateProductIndication(productDefinition.productFactory, assignment.productIndication, assignment.indicationId);
        }

        definitionStorage.productDefinition = productDefinition;
        _touchProductDefinition(definitionStorage);

        emit ProductDefinitionUpdated(productDefinitionId, productDefinition.productFactory, productDefinition.productTermsTemplate, productDefinition.productDocumentationTemplate, definitionStorage.version);
        emit StatePartUpdated(msg.sender, address(this), _partIdFromProductDefinitionId(productDefinitionId), definitionStorage.version);
    }

    function setProductDefinitionStatus(bytes32 productDefinitionId, ProductDefinitionStatus newStatus) external override onlyOwner {
        ProductDefinitionStorage storage definitionStorage = _existingProductDefinition(productDefinitionId);
        ProductDefinitionStatus oldStatus = definitionStorage.status;

        if (oldStatus == newStatus) {
            return;
        }
        _validateStatusTransition(oldStatus, newStatus);

        definitionStorage.status = newStatus;
        definitionStorage.updatedAt = uint64(block.timestamp);
        ++stateVersion;

        emit ProductDefinitionStatusChanged(productDefinitionId, oldStatus, newStatus);
        emit StatePartUpdated(msg.sender, address(this), _partIdFromProductDefinitionId(productDefinitionId), definitionStorage.version);
    }

    // ------------------------------ Product Definition Read API ------------------------------ */

    /// @notice Number of definitions ever published, including inactive definitions.
    function productDefinitionCount() external view returns (uint256) {
        return _productDefinitionIds.length();
    }

    /// @inheritdoc IProductDefinitionRegistry
    function productDefinitionState(bytes32 productDefinitionId) external view override returns (ProductDefinitionState memory) {
        return _productDefinitionState(productDefinitionId);
    }

    /**
     * @notice Compact definition states in first-publication order, regardless of status.
     * @dev At most MAX_DISCOVERY_PAGE_SIZE records; zero limit or an out-of-range offset returns an empty page.
     *      Pin successive reads to the same block when a consistent snapshot is required.
     */
    function getProductDefinitionStates(uint256 offset, uint256 limit) external view returns (ProductDefinitionState[] memory items) {
        uint256 count = _discoveryPageLength(_productDefinitionIds.length(), offset, limit);
        items = new ProductDefinitionState[](count);
        for (uint256 i; i < count; ++i) {
            items[i] = _productDefinitionState(_productDefinitionIds.at(offset + i));
        }
    }

    function getProductDefinition(bytes32 productDefinitionId) external view override returns (ProductDefinitionView memory) {
        ProductDefinitionStorage storage definitionStorage = _existingProductDefinition(productDefinitionId);
        return ProductDefinitionView({
            status: definitionStorage.status,
            publishedAt: definitionStorage.publishedAt,
            updatedAt: definitionStorage.updatedAt,
            name: definitionStorage.name,
            partId: _partIdFromProductDefinitionId(productDefinitionId),
            version: definitionStorage.version,
            productDefinition: definitionStorage.productDefinition
        });
    }

    function getProductFactoryByDefinitionId(bytes32 productDefinitionId) external view override returns (address productFactory) {
        return _existingProductDefinition(productDefinitionId).productDefinition.productFactory;
    }

    function getProductDefinitionStatus(bytes32 productDefinitionId) external view override returns (ProductDefinitionStatus) {
        return _productDefinitionsById[productDefinitionId].status;
    }

    // ------------------------------ Product Indication Assignment ------------------------------ */

    /// @notice Assigns (or replaces) the product indication of a product definition.
    function setProductIndication(bytes32 productDefinitionId, address productIndication, bytes32 indicationId) external onlyOwner {
        ProductDefinitionStorage storage definitionStorage = _existingProductDefinition(productDefinitionId);
        _ensureProductDefinitionWritable(productDefinitionId, definitionStorage.status);

        uint256 partId = _validateProductIndication(definitionStorage.productDefinition.productFactory, productIndication, indicationId);

        ProductIndicationAssignment storage assignment = _indicationsByDefinitionId[productDefinitionId];
        if (assignment.productIndication == productIndication && assignment.indicationId == indicationId && assignment.partId == partId) {
            return;
        }
        assignment.productIndication = productIndication;
        assignment.indicationId = indicationId;
        assignment.partId = partId;
        definitionStorage.updatedAt = uint64(block.timestamp);
        ++stateVersion;

        emit ProductIndicationAssigned(productDefinitionId, productIndication, indicationId);
        emit StatePartUpdated(msg.sender, address(this), _partIdFromProductDefinitionId(productDefinitionId), definitionStorage.version);
    }

    /// @notice Clears the indication assigned to a product definition.
    function clearProductIndication(bytes32 productDefinitionId) external onlyOwner {
        ProductDefinitionStorage storage definitionStorage = _existingProductDefinition(productDefinitionId);
        _ensureProductDefinitionWritable(productDefinitionId, definitionStorage.status);

        _existingProductIndicationAssignment(productDefinitionId);
        delete _indicationsByDefinitionId[productDefinitionId];
        definitionStorage.updatedAt = uint64(block.timestamp);
        ++stateVersion;

        emit ProductIndicationCleared(productDefinitionId);
        emit StatePartUpdated(msg.sender, address(this), _partIdFromProductDefinitionId(productDefinitionId), definitionStorage.version);
    }

    /**
     * @notice Returns the indication assigned to a product definition.
     * @dev Does not revalidate the indication's current lifecycle status.
     */
    function productIndicationOfDefinition(bytes32 productDefinitionId) external view returns (address productIndication, bytes32 indicationId, uint256 partId) {
        ProductIndicationAssignment storage assignment = _existingProductIndicationAssignment(productDefinitionId);
        return (assignment.productIndication, assignment.indicationId, assignment.partId);
    }

    // ------------------------------ Product Issuance ------------------------------ */

    /// @inheritdoc IProductDefinitionRegistry
    function isRegisteredProduct(address product) external view override returns (bool) {
        return _isRegisteredProduct[product];
    }

    /// @inheritdoc IProductDefinitionRegistry
    function issueProduct(bytes32 productDefinitionId, uint256 expectedVersion, bytes calldata productPayload)
        external override nonReentrant returns (address product)
    {
        address provider = TradingContractFactory(tradingContractFactory).clientOf(msg.sender);
        if (provider == address(0)) revert UnrecognizedTradingContract(msg.sender);
        if (!IClientRegistry(clientRegistryAddress).isEligibleClient(provider, productDefinitionId)) {
            revert ClientNotEligible(provider, productDefinitionId);
        }

        ProductDefinitionStorage storage definition = _fulfillableProductDefinition(productDefinitionId);
        if (definition.version != expectedVersion) {
            revert ProductDefinitionVersionMismatch(productDefinitionId, expectedVersion, definition.version);
        }
        ProductDefinition storage components = definition.productDefinition;
        IProductFactory factory = IProductFactory(components.productFactory);
        product = factory.deployProduct(ProductDeploymentParams({
            common: CommonDeploymentParams({
                productRegistry: address(this),
                productProvider: provider,
                productDefinitionId: productDefinitionId,
                productDefinitionVersion: expectedVersion,
                productTermsTemplate: components.productTermsTemplate,
                productDocumentationTemplate: components.productDocumentationTemplate
            }),
            productPayload: productPayload
        }));
        _validateProductDeployment(product, factory);
        _isRegisteredProduct[product] = true;
        emit ProductIssued(productDefinitionId, expectedVersion, product);
    }

    // ------------------------------ XML View ------------------------------ */

    function statePartXmlTemplate(uint256 partId) external view override returns (string memory) {
        bytes32 productDefinitionId = _productDefinitionIdFromPartId(partId);
        ProductDefinitionStorage storage definition = _productDefinitionsById[productDefinitionId];
        if (definition.status == ProductDefinitionStatus.Unknown) {
            revert UnknownPart(partId);
        }
        return _productDefinitionStateXml(productDefinitionId, definition);
    }


    /// @notice Returns the XML representation of a product definition.
    function _productDefinitionStateXml(bytes32 productDefinitionId, ProductDefinitionStorage storage definitionStorage) internal view returns (string memory) {
        return string.concat(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<ProductDefinition xmlns:xi=\"http://www.w3.org/2001/XInclude\"",
            " xmlns:evmstate=\"urn:evm:state:1.0\"",
            " productDefinitionId=\"", _bytes32ToHexString(productDefinitionId), "\"",
            " name=\"", LibString.escapeHTML(definitionStorage.name), "\"",
            " status=\"", uint256(definitionStorage.status).toString(), "\"",
            " version=\"", definitionStorage.version.toString(), "\"",
            " updatedAt=\"", uint256(definitionStorage.updatedAt).toString(), "\"",
            ">",
            "<ProductFactory contractAddress=\"", Strings.toHexString(definitionStorage.productDefinition.productFactory),
            "\"/>",
            "<ProductResources>",
            "<ProductTermsTemplate>",
            _include(definitionStorage.productDefinition.productTermsTemplate),
            "</ProductTermsTemplate>",
            _resourceReference(
                "ProductDocumentationTemplate",
                definitionStorage.productDefinition.productDocumentationTemplate
            ),
            "</ProductResources>",
            _productIndicationAssignmentXml(productDefinitionId),
            "</ProductDefinition>"
        );
    }

    function _include(address resource) internal view returns (string memory) {
        ITextResource textResource = ITextResource(resource);
        string memory href = textResource.web3Url();
        return string.concat(
            "<xi:include href=\"", LibString.escapeHTML(href),
            "\" parse=\"text\" evmstate:integrity=\"", _integrity(textResource.contentHash()), "\"/>"
        );
    }

    function _productIndicationAssignmentXml(bytes32 productDefinitionId) internal view returns (string memory) {
        ProductIndicationAssignment storage assignment = _indicationsByDefinitionId[productDefinitionId];
        if (assignment.productIndication == address(0)) {
            return "<ProductIndicationAssignment assigned=\"false\"/>";
        }

        return string.concat(
            "<ProductIndicationAssignment assigned=\"true\"",
            " contractAddress=\"", Strings.toHexString(assignment.productIndication), "\"",
            " indicationId=\"", _bytes32ToHexString(assignment.indicationId), "\"",
            " partId=\"", assignment.partId.toString(), "\"",
            "/>"
        );
    }

    /// @notice Returns an XML reference to a finalized text resource.
    function _resourceReference(string memory elementName, address resource) internal view returns (string memory) {
        ITextResource textResource = ITextResource(resource);
        return string.concat(
            "<",
            elementName,
            " href=\"",
            LibString.escapeHTML(textResource.web3Url()),
            "\" integrity=\"",
            _integrity(textResource.contentHash()),
            "\"/>"
        );
    }

    function _integrity(bytes32 contentHash) internal pure returns (string memory integrity) {
        integrity = string.concat("keccak256-", _bytes32ToHexString(contentHash));
    }

    // ------------------------------ Internal Key / Hash Logic ------------------------------ */

    function computeProductDefinitionId(string calldata name) external view override returns (bytes32 productDefinitionId) {
        return _productDefinitionId(name);
    }

    function _productDefinitionId(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encode(name, address(this)));
    }

    function _productDefinitionIdFromPartId(uint256 partId) internal pure returns (bytes32) {
        return bytes32(partId);
    }

    function _partIdFromProductDefinitionId(bytes32 productDefinitionId) internal pure returns (uint256) {
        return uint256(productDefinitionId);
    }

    /// @dev Only component publication/update advances the version to which trade requests are bound.
    function _touchProductDefinition(ProductDefinitionStorage storage definitionStorage) internal {
        unchecked { definitionStorage.version += 1; }
        definitionStorage.updatedAt = uint64(block.timestamp);
        ++stateVersion;
    }

    function _productDefinitionState(bytes32 productDefinitionId) internal view returns (ProductDefinitionState memory) {
        ProductDefinitionStorage storage definition = _existingProductDefinition(productDefinitionId);
        return ProductDefinitionState({
            productDefinitionId: productDefinitionId,
            status: definition.status,
            publishedAt: definition.publishedAt,
            updatedAt: definition.updatedAt,
            version: definition.version
        });
    }

    function _discoveryPageLength(uint256 length, uint256 offset, uint256 limit) internal pure returns (uint256) {
        if (offset >= length) {
            return 0;
        }
        uint256 count = length - offset;
        if (count > limit) count = limit;
        if (count > MAX_DISCOVERY_PAGE_SIZE) count = MAX_DISCOVERY_PAGE_SIZE;
        return count;
    }

    // ------------------------------ Validation Helpers ------------------------------ */

    function _existingProductDefinition(bytes32 productDefinitionId) internal view returns (ProductDefinitionStorage storage definition) {
        definition = _productDefinitionsById[productDefinitionId];
        if (definition.status == ProductDefinitionStatus.Unknown) {
            revert UnknownProductDefinition(productDefinitionId);
        }
    }

    /// @dev Existing requests may still be fulfilled while a definition is suspended.
    function _fulfillableProductDefinition(bytes32 productDefinitionId) internal view returns (ProductDefinitionStorage storage definition) {
        definition = _existingProductDefinition(productDefinitionId);
        if (definition.status != ProductDefinitionStatus.Active && definition.status != ProductDefinitionStatus.Suspended) {
            revert ProductDefinitionNotFulfillable(productDefinitionId, definition.status);
        }
    }

    function _existingProductIndicationAssignment(bytes32 productDefinitionId) internal view returns (ProductIndicationAssignment storage assignment) {
        assignment = _indicationsByDefinitionId[productDefinitionId];
        if (assignment.productIndication == address(0)) {
            revert MissingProductIndication(productDefinitionId);
        }
    }

    function _ensureProductDefinitionWritable(bytes32 productDefinitionId, ProductDefinitionStatus status) internal pure {
        if (status == ProductDefinitionStatus.Retired || status == ProductDefinitionStatus.Archived) {
            revert ProductDefinitionNotWritable(productDefinitionId, status);
        }
    }

    /**
     * @dev Allowed transitions:
     *      Active    -> Suspended | Retired
     *      Suspended -> Active | Retired
     *      Retired    -> Archived
     *      Archived  -> (terminal)
     */
    function _validateStatusTransition(ProductDefinitionStatus  oldStatus, ProductDefinitionStatus  newStatus) internal pure {
        bool valid = (oldStatus == ProductDefinitionStatus.Active && (newStatus == ProductDefinitionStatus.Suspended || newStatus == ProductDefinitionStatus.Retired)) ||
            (oldStatus == ProductDefinitionStatus.Suspended && (newStatus == ProductDefinitionStatus.Active || newStatus == ProductDefinitionStatus.Retired)) ||
            (oldStatus == ProductDefinitionStatus.Retired && newStatus == ProductDefinitionStatus.Archived);
        if (!valid) revert InvalidStatusTransition(oldStatus, newStatus);
    }

    function _validateProductDefinitionPublicationParams(ProductDefinitionPublicationParams calldata params) internal view {
        if (bytes(params.name).length == 0) {
            revert EmptyString("name");
        }
        _validateProductDefinition(params.productDefinition);
    }

    function _validateProductDefinition(ProductDefinition calldata productDefinition) internal view {
        IProductFactory factory = IProductFactory(productDefinition.productFactory);
        _validateProductFactory(productDefinition.productFactory);
        _validateTextResource(productDefinition.productTermsTemplate, factory.productTermsTemplateResourceType());
        _validateTextResource(productDefinition.productDocumentationTemplate, factory.productDocumentationTemplateResourceType());
    }

    function _validateProductFactory(address factory) internal view {
        _validateContractAddress(factory, "productFactory");
        // Must advertise IProductFactory via ERC-165
        if (!factory.supportsInterface(type(IProductFactory).interfaceId)) {
            revert InvalidInterface(factory);
        }
        IProductFactory productFactory = IProductFactory(factory);
        // Factory must be configured for this registry
        try productFactory.productRegistryAddress() returns (address configuredAddress) {
            if (configuredAddress != address(this)) revert FactoryNotConfigured(configuredAddress);
        } catch {
            revert ContractCallFailed(factory, "productRegistryAddress()");
        }
        // Factory must implement meaningful product specifications: productPayloadSchema, productTermsTemplateResourceType, productDocumentationTemplateResourceType
        if (bytes(productFactory.productPayloadSchema()).length == 0) {
            revert InvalidProductFactory(factory);
        }
        if (productFactory.productTermsTemplateResourceType() == bytes32(0) || productFactory.productDocumentationTemplateResourceType() == bytes32(0)) {
            revert InvalidProductFactory(factory);
        }
    }

    function _validateTextResource(address resource, bytes32 expectedResourceType) internal view {
        _validateContractAddress(resource, "textResource");
        // Must advertise ITextResource via ERC-165
        if(!resource.supportsInterface(type(ITextResource).interfaceId)) {
            revert InvalidInterface(resource);
        }
        ITextResource textResource = ITextResource(resource);
        // TextResource must be finalized (immutable).
        try textResource.isFinalized() returns (bool finalized) {
            if (!finalized)  revert ResourceNotFinalized(resource);
        } catch {
            revert ContractCallFailed(resource, "isFinalized()");
        }
        // Must carry an accepted resource type
        try textResource.resourceType() returns (bytes32 actualResourceType) {
            if (actualResourceType != expectedResourceType) revert InvalidResourceType(resource, expectedResourceType, actualResourceType);
        } catch {
            revert ContractCallFailed(resource, "resourceType()");
        }
    }

    function _validateProductIndication(address productFactory, address productIndication, bytes32 indicationId) internal view returns (uint256 partId) {
        _validateContractAddress(productIndication, "productIndication");
        if (indicationId == bytes32(0)) revert ZeroHash("indicationId");
        // Must advertise IProductIndication via ERC-165
        if (!productIndication.supportsInterface(type(IProductIndication).interfaceId)) {
            revert InvalidInterface(productIndication);
        }
        IProductIndication indication = IProductIndication(productIndication);
        // Indication must be in valid state
        try indication.indicationStatus(indicationId) returns (IProductIndication.IndicationStatus status) {
            if (status != IProductIndication.IndicationStatus.Active && status != IProductIndication.IndicationStatus.Suspended) {
                revert InvalidIndicationStatus(productIndication, status);
            }
        } catch {
            revert ContractCallFailed(productIndication, "indicationStatus()");
        }
        // Indication must be of a category accepted by the product / product factory
        try indication.indicationCategory() returns (bytes32 category) {
            if (!IProductFactory(productFactory).isAcceptedIndicationCategory(category)) {
                revert UnsupportedIndicationCategory(productIndication, category);
            }
        } catch {
            revert ContractCallFailed(productIndication, "indicationCategory()");
        }
        // Get partId of the indication (used for rendering)
        try indication.partIdForIndication(indicationId) returns (uint256 resolvedPartId) {
            partId = resolvedPartId;
        } catch {
            revert ContractCallFailed(productIndication, "partIdForIndication()");
        }
    }

    function _validateContractAddress(address contractAddress, string memory field) internal view {
        if (contractAddress == address(0)) revert ZeroAddress(field);
        if (contractAddress.code.length == 0) revert EmptyContract(contractAddress);
    }

    function _validateProductDeployment(address product, IProductFactory factory) internal view {
        if (product == address(0) || product.code.length == 0) {
            revert ProductDeploymentFailed(address(factory));
        }
        if (!factory.isFactoryDeployedProduct(product)) {
            revert InvalidDeployedProduct(address(factory),product);
        }
    }

    // ------------------------------ String Helpers ------------------------------ */

    function _bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        return uint256(value).toHexString(32);
    }

}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IXMLRepresentableState} from "../../erc8100/IRepresentableState.sol";
import {ProductLib} from "./ProductLib.sol";

import {IProduct} from "./IProduct.sol";
import {CommonDeploymentParams} from "../productFactories/ProductDeploymentTypes.sol";

/**
 * @title AbstractProduct
 * @notice Base contract for deployed products with immutable deployment state
 *         and XML rendering helpers.
 *
 * @dev The deployment context contains no counterparty: products may be issued
 *      with or without preceding trade requests.
 *
 * @dev This base fixes the XML envelope for every deployed product. Concrete
 *      products supply only their type name and schema version via _productType().
 *      String construction stays in the linked ProductLib to keep factory code small.
 *
 * @author Raphael Prandtl
 */
abstract contract AbstractProduct is IProduct, IXMLRepresentableState {
    // ------------------------------ Events ------------------------------ */

    /// @notice Emitted when the product state changes.
    event StateUpdated(address indexed sender, address indexed stateContract, bytes32 currentStateHash);

    // ------------------------------ Immutable State ------------------------------ */

    /// @inheritdoc IProduct
    address public immutable override productFactory;
    /// @inheritdoc IProduct
    address public immutable override productRegistry;
    /// @inheritdoc IProduct
    address public immutable override productProvider;
    /// @inheritdoc IProduct
    bytes32 public immutable override productDefinitionId;
    /// @inheritdoc IProduct
    uint256 public immutable override productDefinitionVersion;
    /// @inheritdoc IProduct
    address public immutable override productTermsTemplate;

    // ------------------------------ Legal Documentation ------------------------------ */

    /// @inheritdoc IProduct
    address public override legalDocumentation;
    /// @inheritdoc IProduct
    bytes32 public override legalDocumentationHash;

    // ------------------------------ Custom Errors ------------------------------ */

    /// @notice Thrown when a required address is zero.
    error ZeroAddress(string field);

    /// @notice Thrown when a required bytes32 value is zero.
    error ZeroHash(string field);

    /// @notice The supplied contract must implement ITextResource and expose a nonzero finalized digest.
    error InvalidLegalDocumentation(address documentation);

    /// @notice The legal documentation must be finalized before the first offer.
    error LegalDocumentationNotFinalized(address documentation);

    /// @notice Further offers on this product must use its original legal documentation.
    error LegalDocumentationAlreadySet(address existing, address supplied);

    // ------------------------------ Constructor ------------------------------ */

    /**
     * @notice Initializes the immutable deployment context.
     * @dev Called by the product factory; msg.sender is recorded as productFactory.
     * @param common Common deployment parameters assembled by the product registry.
     */
    constructor(CommonDeploymentParams memory common) {
        ProductLib.validateDeploymentContext(common);

        productFactory = msg.sender;
        productRegistry = common.productRegistry;
        productProvider = common.productProvider;
        productDefinitionId = common.productDefinitionId;
        productDefinitionVersion = common.productDefinitionVersion;
        productTermsTemplate = common.productTermsTemplate;
    }

    /// @dev Bind one resource and its hash for the lifetime of this product, including after a canceled offer.
    function _bindLegalDocumentation(address documentation) internal {
        address existing = legalDocumentation;
        if (existing == address(0)) {
            legalDocumentationHash = ProductLib.legalDocumentationHash(documentation);
            legalDocumentation = documentation;
        } else if (documentation != existing) {
            revert LegalDocumentationAlreadySet(existing, documentation);
        }
    }

    /// @inheritdoc IProduct
    function legalDocumentationURI() external view override returns (string memory) {
        return ProductLib.legalDocumentationURI(legalDocumentation);
    }

    // ------------------------------ XML View ------------------------------ */

    /// @inheritdoc IXMLRepresentableState
    function stateXmlTemplate() external view override returns (string memory) {
        (string memory name, string memory version) = _productType();
        return ProductLib.productStateXml(productTermsTemplate, legalDocumentation, legalDocumentationHash, name, version);
    }

    /// @dev Product-type schema identity; independent of a registry's productDefinitionVersion.
    function _productType() internal pure virtual returns (string memory name, string memory version);
}

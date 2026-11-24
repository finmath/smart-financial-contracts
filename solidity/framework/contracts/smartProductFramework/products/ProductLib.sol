// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {CommonDeploymentParams} from "../productFactories/ProductDeploymentTypes.sol";
import {ITextResource} from "../../erc8100/ITextResource.sol";

/**
 * @title ProductLib
 * @notice Shared XML and trade-data string helpers for deployed products.
 * @dev The external entry points keep string processing out of product creation
 *      bytecode, which is also embedded in its factory. AbstractProduct fixes the
 *      envelope; products provide only their type name and type schema version.
 */
library ProductLib {
    using Strings for uint256;

    /// @dev Same selector as the product's InvalidTradeData error.
    error InvalidTradeData();

    /// @dev Same selectors as AbstractProduct; validation stays in the constructor's delegatecall.
    error ZeroAddress(string field);
    error ZeroHash(string field);
    error InvalidLegalDocumentation(address documentation);
    error LegalDocumentationNotFinalized(address documentation);

    function validateDeploymentContext(CommonDeploymentParams memory common) external pure {
        if (common.productRegistry == address(0)) {
            revert ZeroAddress("productRegistry");
        }
        if (common.productProvider == address(0)) {
            revert ZeroAddress("productProvider");
        }
        if (common.productDefinitionId == bytes32(0)) {
            revert ZeroHash("productDefinitionId");
        }
        if (common.productTermsTemplate == address(0)) {
            revert ZeroAddress("productTermsTemplate");
        }
    }

    /// @notice Reads the content hash of a finalized legal documentation resource.
    function legalDocumentationHash(address documentation) external view returns (bytes32 digest) {
        if (!ERC165Checker.supportsInterface(documentation, type(ITextResource).interfaceId)) {
            revert InvalidLegalDocumentation(documentation);
        }
        ITextResource resource = ITextResource(documentation);
        if (!resource.isFinalized()) revert LegalDocumentationNotFinalized(documentation);
        digest = resource.contentHash();
        if (digest == bytes32(0)) revert InvalidLegalDocumentation(documentation);
    }

    /// @notice Canonical content locator for the legal documentation on this chain.
    function legalDocumentationURI(address documentation) public view returns (string memory) {
        if (documentation == address(0)) return "";
        return string.concat("web3://", Strings.toHexString(documentation), ":", block.chainid.toString(), "/content");
    }

    /**
     * @notice Builds the common SmartFinancialProduct XML envelope.
     * @dev The definition pins the ICMA BDT terms template. The first successful
     *      inception pins the legal documentation resource and its content hash.
     */
    function productStateXml(
        address termsTemplate,
        address documentation,
        bytes32 documentationHash,
        string memory productType,
        string memory typeVersion
    ) external view returns (string memory) {
        return string.concat(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<SmartFinancialProduct xmlns=\"urn:smart-product-framework:financial-product:2.0\"",
            " xmlns:xi=\"http://www.w3.org/2001/XInclude\"",
            " xmlns:evmstate=\"urn:evm:state:1.0\"",
            " schemaVersion=\"2.0.0\"",
            " type=\"", LibString.escapeHTML(productType),
            "\" typeVersion=\"", LibString.escapeHTML(typeVersion), "\">",
            _deploymentStateXml(),
            "<ProductResources>",
            "<ProductTermsTemplate type=\"ICMABondDataTaxonomy\"",
            " version=\"2.1.0\"",
            " namespace=\"urn:icma:xsd:ICMABondDataTaxonomy\"",
            _mediaTypeAttribute(ITextResource(termsTemplate)), ">",
            _include(ITextResource(termsTemplate)),
            "</ProductTermsTemplate>",
            _legalDocumentationXml(documentation, documentationHash),
            "</ProductResources></SmartFinancialProduct>"
        );
    }

    /// @notice Renders the trade identifier as a checksum-free hex product address.
    function tradeId(address product) external pure returns (string memory) {
        return uint256(uint160(product)).toHexString(20);
    }

    /// @notice Identifies an ICMA BDT 2.1.0 document by chain, product and represented-state revision.
    /// @dev Runs in the product's context. Decimal integers and a lowercase,
    ///      zero-padded address make the identifier canonical; the full revision must be available.
    function documentId(uint256 version) external view returns (string memory) {
        return string.concat(
            "sbc:icma-bdt:2.1.0:", block.chainid.toString(), ":",
            uint256(uint160(address(this))).toHexString(20), ":", version.toString()
        );
    }

    /// @notice Reads a lowercase, 0x-prefixed ABI encoding of (address, bytes32).
    function decodeOfferData(string memory data) external pure returns (address documentation, bytes32 agreementHash) {
        bytes memory hexData = bytes(data);
        if (hexData.length != 130 || hexData[0] != "0" || hexData[1] != "x") revert InvalidTradeData();
        uint256 addressWord = _parseDigits(hexData, 2, 66, false);
        if (addressWord > type(uint160).max) revert InvalidTradeData();
        return (address(uint160(addressWord)), bytes32(_parseDigits(hexData, 66, 130, false)));
    }

    /// @notice Parses a 0x-prefixed 32-byte hash.
    function parseHash(string memory s) external pure returns (bytes32) {
        bytes memory b = bytes(s);
        if (b.length != 66 || b[0] != "0" || b[1] != "x") revert InvalidTradeData();
        return bytes32(_parseDigits(b, 2, b.length, true));
    }

    function _parseDigits(bytes memory b, uint256 start, uint256 end, bool allowUppercase) private pure returns (uint256 value) {
        for (uint256 i = start; i < end; ++i) {
            uint8 digit = uint8(b[i]);
            if (digit >= 48 && digit <= 57) digit -= 48;
            else if (digit >= 97 && digit <= 102) digit -= 87;
            else if (allowUppercase && digit >= 65 && digit <= 70) digit -= 55;
            else revert InvalidTradeData();
            value = (value << 4) | digit;
        }
    }

    function _deploymentStateXml() private pure returns (string memory) {
        return string.concat(
            "<DeploymentState>",
            "<ProductRegistry evmstate:call=\"productRegistry()(address)\"/>",
            "<ProductFactory evmstate:call=\"productFactory()(address)\"/>",
            "<ProductProvider evmstate:call=\"productProvider()(address)\"/>",
            "<ProductDefinitionId evmstate:call=\"productDefinitionId()(bytes32)\"/>",
            "<ProductDefinitionVersion evmstate:call=\"productDefinitionVersion()(uint256)\"/>",
            "</DeploymentState>"
        );
    }

    function _mediaTypeAttribute(ITextResource resource) private view returns (string memory) {
        return string.concat(
            " mediaType=\"", LibString.escapeHTML(resource.mediaType()), "\""
        );
    }

    function _include(ITextResource resource) private view returns (string memory) {
        return string.concat(
            "<xi:include href=\"", LibString.escapeHTML(resource.web3Url()),
            "\" parse=\"xml\" evmstate:integrity=\"", _integrity(resource.contentHash()), "\"/>"
        );
    }

    function _integrity(bytes32 contentHash) private pure returns (string memory) {
        return string.concat("keccak256-", uint256(contentHash).toHexString(32));
    }

    function _legalDocumentationXml(address documentation, bytes32 digest) private view returns (string memory) {
        if (documentation == address(0)) return "";
        return string.concat('<LegalDocumentation href="', legalDocumentationURI(documentation), '" integrity="', _integrity(digest), '"/>');
    }

}

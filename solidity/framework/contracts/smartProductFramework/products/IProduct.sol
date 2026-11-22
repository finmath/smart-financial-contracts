// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IProduct
 * @notice Exposes the product's deployment context and its legal documentation.
 *
 * @dev The registry fixes the common deployment context at construction. Concrete
 *      products define their counterparties and agreement lifecycle.
 *
 * @author Raphael Prandtl
 */
interface IProduct {
    // ------------------------------ Deployment State ------------------------------ */

    /// @notice Returns the factory that deployed the product.
    function productFactory() external view returns (address);

    /// @notice Returns the product registry that initiated deployment.
    function productRegistry() external view returns (address);

    /// @notice Returns the product provider (issuer/seller) of this product.
    function productProvider() external view returns (address);

    /// @notice Returns the product definition used for deployment.
    function productDefinitionId() external view returns (bytes32);

    /// @notice Returns the product definition version used for deployment.
    function productDefinitionVersion() external view returns (uint256);

    /// @notice Returns the product terms template resource.
    function productTermsTemplate() external view returns (address);

    // ------------------------------ Legal Documentation ------------------------------ */

    /// @notice Finalized text resource fixed by the first successful trade inception, or zero before it.
    function legalDocumentation() external view returns (address);

    /// @notice Keccak-256 of the legal documentation bytes captured at first inception, or zero before it.
    function legalDocumentationHash() external view returns (bytes32);

    /// @notice Canonical web3 URI of the legal documentation, or an empty string before first inception.
    function legalDocumentationURI() external view returns (string memory);
}

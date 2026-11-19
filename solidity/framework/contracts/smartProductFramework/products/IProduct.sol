// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IProduct
 * @notice Exposes the product's deployment context and offered legal manifest.
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

    // ------------------------------ Offer State ------------------------------ */

    /// @notice Finalized text resource selected at trade inception; zero before the first offer.
    function legalDocumentsManifest() external view returns (address);

    /// @notice Keccak-256 of the manifest bytes captured at trade inception; zero before the first offer.
    function legalDocumentsHash() external view returns (bytes32);

    /// @notice Canonical web3 URI for the offered manifest, or the empty string before an offer.
    function legalDocumentsURI() external view returns (string memory);
}

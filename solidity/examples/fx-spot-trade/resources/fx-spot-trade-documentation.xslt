<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:fx="urn:example:fx-spot-trade" version="1.0" exclude-result-prefixes="fx">
  <xsl:output method="html" encoding="UTF-8"/>
  <xsl:template match="/fx:FxSpotTrade">
    <html><head><title>FX Spot Trade</title>
      <style>body{font:16px system-ui,sans-serif;max-width:72rem;margin:2rem auto;padding:0 1rem;color:#172033}table{border-collapse:collapse;width:100%;margin:1rem 0}th,td{border:1px solid #ccd2dc;text-align:left;padding:.6rem;overflow-wrap:anywhere}th{background:#f1f4f8}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style>
    </head><body>
      <h1>FX Spot Trade</h1>
      <p>Atomic payment-versus-payment settlement of two currency-token amounts.</p>
      <p>Trade ID: <xsl:value-of select="fx:Lifecycle/fx:TradeId"/>. State:
        <xsl:choose>
          <xsl:when test="fx:Lifecycle/fx:Phase='0'">Created</xsl:when>
          <xsl:when test="fx:Lifecycle/fx:Phase='1'">Incepted</xsl:when>
          <xsl:when test="fx:Lifecycle/fx:Phase='2'">Settled</xsl:when>
          <xsl:when test="fx:Lifecycle/fx:Phase='3'">Canceled</xsl:when>
        </xsl:choose>
      </p>
      <p>Inceptor: <xsl:value-of select="fx:Lifecycle/fx:Inceptor"/></p>
      <table><thead><tr><th>Leg</th><th>Token</th><th>Signed raw amount</th><th>Payer</th><th>Receiver</th></tr></thead><tbody>
        <xsl:call-template name="leg"><xsl:with-param name="role" select="'base'"/><xsl:with-param name="amount" select="fx:Terms/fx:Position"/></xsl:call-template>
        <xsl:call-template name="leg"><xsl:with-param name="role" select="'quote'"/><xsl:with-param name="amount" select="fx:Terms/fx:PaymentAmount"/></xsl:call-template>
      </tbody></table>
      <p>Amounts are exact integers in each token's smallest unit, from the inceptor's perspective: positive receives, negative delivers. The token address does not establish an ISO currency code. These are trade terms; transfers occur only in the Settled state.</p>
      <h2>Trade data</h2><pre><xsl:value-of select="fx:Terms/fx:TradeData"/></pre>
      <h2>Initial settlement data</h2><pre><xsl:value-of select="fx:Terms/fx:InitialSettlementData"/></pre>
    </body></html>
  </xsl:template>
  <xsl:template name="leg">
    <xsl:param name="role"/><xsl:param name="amount"/>
    <xsl:variable name="inceptor" select="fx:Lifecycle/fx:Inceptor"/>
    <xsl:variable name="other" select="fx:Parties/fx:Party[. != $inceptor]"/>
    <tr><td><xsl:value-of select="$role"/></td><td><xsl:value-of select="fx:Tokens/fx:Token[@role=$role]"/></td>
      <!-- Keep int256 values as strings: XSLT 1.0 numbers lose integer precision. -->
      <td><xsl:value-of select="$amount"/></td>
      <td><xsl:choose><xsl:when test="fx:Lifecycle/fx:Phase='0'">-</xsl:when><xsl:when test="starts-with($amount, '-')"><xsl:value-of select="$inceptor"/></xsl:when><xsl:otherwise><xsl:value-of select="$other"/></xsl:otherwise></xsl:choose></td>
      <td><xsl:choose><xsl:when test="fx:Lifecycle/fx:Phase='0'">-</xsl:when><xsl:when test="starts-with($amount, '-')"><xsl:value-of select="$other"/></xsl:when><xsl:otherwise><xsl:value-of select="$inceptor"/></xsl:otherwise></xsl:choose></td>
    </tr>
  </xsl:template>
</xsl:stylesheet>

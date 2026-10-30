set -e

# Local Beam PKI for the SMPC-RL test setup.
# The SecureEpiLinker test endpoint addresses remote Beam apps as
# beamsel.${REMOTE_SITE}.broker, so the proxy certificates must use the
# site names as proxy IDs (SiteA.broker, SiteB.broker).

echo "$VAULT_TOKEN" > /pki/pki.secret

vault secrets enable -path=samply_pki pki

vault write -field=certificate samply_pki/root/generate/internal common_name=broker > /pki/root.crt.pem

vault write samply_pki/roles/myrole allowed_domains=broker allow_subdomains=true

vault write -field=private_key samply_pki/issue/myrole common_name=SiteA.broker ttl=30d > /pki/SiteA.priv.pem
vault write -field=private_key samply_pki/issue/myrole common_name=SiteB.broker ttl=30d > /pki/SiteB.priv.pem

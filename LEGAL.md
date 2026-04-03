# LEGAL RISK CHECKLIST

This document is not legal advice. It is an engineering checklist to reduce obvious distribution risk.

## 1) License and redistribution

- Verify upstream source license terms before public redistribution.
- Verify all bundled files are allowed to be redistributed.
- Keep copyright/license notices required by upstream dependencies.
- If uncertain, do not publish publicly until legal review is complete.

## 2) Branding and trademark

- Do not present this project as an official Anthropic release.
- Keep non-affiliation statements in user-facing docs.
- Avoid misleading package descriptions, release names, and install pages.

## 3) Terms of service compliance

- Ensure provider routing/proxy usage complies with API provider ToS:
  - OpenAI
  - Anthropic
  - Google Gemini
  - Azure OpenAI
  - AWS Bedrock

## 4) Data handling and security

- Never hardcode credentials in repository or release artifacts.
- Do not upload private environment files or internal endpoints.
- Document where logs are written and what they may contain.

## 5) Public release gate

Before publishing a public npm package or GitHub Release:

1. Complete items above.
2. Confirm README and NOTICE are included.
3. Confirm no sensitive data in binaries/scripts/configs.
4. Obtain legal sign-off for external/public distribution when required.

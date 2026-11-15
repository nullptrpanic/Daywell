# Privacy and Support Website

The static website in `website/` supplies the support and privacy pages for Daywell's App Store listing in Simplified Chinese and English. It uses local HTML, CSS, and the app icon, with no JavaScript, analytics, forms, external fonts, or runtime dependencies.

## Public content

- `website/index.html` and `website/en/index.html`: support, setup instructions, FAQs, and the contact address.
- `website/privacy.html` and `website/en/privacy.html`: privacy policy based on the app's local storage and Screen Time behavior.
- `website/styles.css`: shared responsive styling, keyboard focus, and dark appearance.
- `website/assets/app-icon.png`: a copy of the current app icon.

The user explicitly selected `liyufeiat010@gmail.com` as the public contact address. Never substitute another account or expose signing information when publishing.

The site is hosted from the existing `nullptrpanic/Daywell` repository. Local edits and new language routes become public after they reach the publishing branch and the GitHub Pages deployment succeeds. Follow the user's explicit authorization requirements for Git commits and pushes.

## Hosting

Use the existing `nullptrpanic/Daywell` repository and GitHub Actions. Configure the Pages artifact upload with `path: website` so that the contents of `website/` become the website root. Keep the application source, build artifacts, and `.apikey/` credentials outside the Pages artifact.

The public URLs are:

| App Store Connect field | Simplified Chinese | English |
| --- | --- | --- |
| Support URL | `https://nullptrpanic.github.io/Daywell/` | `https://nullptrpanic.github.io/Daywell/en/` |
| Privacy Policy URL | `https://nullptrpanic.github.io/Daywell/privacy.html` | `https://nullptrpanic.github.io/Daywell/en/privacy.html` |

Verify all four URLs anonymously after each deployment. `DaywellWebsite` in `App/SettingsView.swift` opens the matching language according to the app bundle's preferred localization. Keep the case of `Daywell` in the URL. The `website/` source directory is not part of the public URL.

## Publish Website Updates

1. Edit the source in `website/` and verify links, content, and assets locally. Keep the two policies in sync and use the same public contact address in both languages.
2. Review the repository's existing Pages workflow before changing it. In **Settings → Pages → Build and deployment**, the source should be **GitHub Actions**. The workflow must upload `website/` with `actions/upload-pages-artifact` and deploy it with `actions/deploy-pages`.
3. Ensure the website files and workflow are on the publishing branch, and that the workflow's push trigger and deployment environment allow that branch. A workflow created on GitHub may not yet exist in the current local checkout. If creating it locally, check whether the blanket `.*` ignore rule excludes `.github/`, and add a targeted exception as needed while preserving the credential ignore rules.
4. Commit and push only when explicitly authorized by the user, following the global working agreements. Use a focused Conventional Commit for the website changes. No separate website repository or Apple API key is required for Pages publication.
5. Wait for Pages to deploy. Verify the four public pages, stylesheet, and icon return successful responses without requiring a GitHub login.
6. Fill the verified URLs into the corresponding App Store Connect localizations. Publish both language routes before distributing a build that links to them.

## Maintenance

Edit source in `website/`, review privacy statements against actual code changes, and update both policy dates when their contents change. Publish the source files through the current repository's Pages workflow after authorization. If hosting changes, update the policies and `DaywellWebsite` before shipping the next app build.

The policy distinguishes local app data, optional Apple backup/diagnostics services, voluntarily sent support emails, and GitHub Pages visitor logs. Keep those distinctions accurate; a statement about no app telemetry does not mean the hosting or email providers never process personal data.

## Verification

- Check relative links and local assets; Pages serves this site under a project subpath.
- Check the language links in both directions and the support address in each language.
- Check phone-width layout, readable text, keyboard navigation, and light/dark appearance.
- Keep preview outputs, ZIP archives, build logs, and DerivedData under `build/`.
- Compile the app after changing its Settings links.

References: [Apple privacy requirements](https://developer.apple.com/app-store/app-privacy-details/), [App Review Guidelines 5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage), [GitHub Pages setup](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site), [Custom GitHub Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

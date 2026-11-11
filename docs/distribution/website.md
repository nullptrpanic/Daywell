# Privacy and Support Website

The buildless website in `website/` supplies the two public pages required for Daywell's App Store listing. It uses only local HTML, CSS, and the existing app icon. It has no JavaScript, analytics, forms, external fonts, or runtime dependencies.

## Public content

- `website/index.html`: support, setup instructions, FAQs, and the contact address.
- `website/privacy.html`: privacy policy based on the app's current local storage and Screen Time behavior.
- `website/styles.css`: shared responsive styling, keyboard focus, and dark appearance.
- `website/assets/app-icon.png`: a copy of the current app icon.

The user explicitly selected `liyufeiat010@gmail.com` as the public contact address. Never substitute another account or expose signing information when publishing.

**Current status:** The site is hosted from the existing `nullptrpanic/Daywell` repository. Both public pages, the stylesheet, and the app icon were verified accessible on 2026-11-11. Local edits become public only after they reach the publishing branch and the GitHub Pages deployment succeeds. Follow the user's explicit authorization requirements for Git commits and pushes.

## Hosting

Use the existing `nullptrpanic/Daywell` repository and GitHub Actions. Configure the Pages artifact upload with `path: website` so that the contents of `website/` become the website root. Keep the application source, build artifacts, and `.apikey/` credentials outside the Pages artifact.

The public URLs are:

| App Store Connect field | URL |
| --- | --- |
| Support URL | `https://nullptrpanic.github.io/Daywell/` |
| Privacy Policy URL | `https://nullptrpanic.github.io/Daywell/privacy.html` |

Verify both URLs anonymously after each deployment. The app's Settings links use the same base URL in `DaywellWebsite` in `App/SettingsView.swift`. Keep the case of `Daywell` in the URL. The `website/` source directory is not part of the public URL.

## Publish Website Updates

1. Edit the source in `website/` and verify links, content, and assets locally. Keep the public contact address consistent on both pages.
2. Review the repository's existing Pages workflow before changing it. In **Settings → Pages → Build and deployment**, the source should be **GitHub Actions**. The workflow must upload `website/` with `actions/upload-pages-artifact` and deploy it with `actions/deploy-pages`.
3. Ensure the website files and workflow are on the publishing branch, and that the workflow's push trigger and deployment environment allow that branch. A workflow created on GitHub may not yet exist in the current local checkout. If creating it locally, check whether the blanket `.*` ignore rule excludes `.github/`, and add a targeted exception as needed while preserving the credential ignore rules.
4. Commit and push only when explicitly authorized by the user, following the global working agreements. Use a focused Conventional Commit for the website changes. No separate website repository or Apple API key is required for Pages publication.
5. Wait for the Pages deployment to succeed. Verify both public pages, the stylesheet, and icon return successful responses without requiring a GitHub login, and confirm that the published content matches the intended update.
6. Fill the verified URLs into App Store Connect. Changes to the App's link destinations require a new build with an incremented build number. Changes confined to website text or styling are published through Pages and do not require an App rebuild.

## Maintenance

Edit source in `website/`, review privacy statements against actual code changes, and update the policy's date when its contents change. Publish the source files through the current repository's Pages workflow after authorization. If hosting changes, update both the policy's hosting section and `DaywellWebsite` before shipping the next app build.

The policy distinguishes local app data, optional Apple backup/diagnostics services, voluntarily sent support emails, and GitHub Pages visitor logs. Keep those distinctions accurate; a statement about no app telemetry does not mean the hosting or email providers never process personal data.

## Verification

- Check relative links and local assets; Pages serves this site under a project subpath.
- Check the support address and mail links on both pages.
- Check phone-width layout, readable text, keyboard navigation, and light/dark appearance.
- Keep preview outputs, ZIP archives, build logs, and DerivedData under `build/`.
- Compile the app after changing its Settings links.

References: [Apple privacy requirements](https://developer.apple.com/app-store/app-privacy-details/), [App Review Guidelines 5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage), [GitHub Pages setup](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site), [Custom GitHub Pages workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

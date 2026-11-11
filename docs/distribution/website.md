# Privacy and Support Website

The buildless website in `website/` supplies the two public pages required for Daywell's App Store listing. It uses only local HTML, CSS, and the existing app icon. It has no JavaScript, analytics, forms, external fonts, or runtime dependencies.

## Public content

- `website/index.html`: support, setup instructions, FAQs, and the contact address.
- `website/privacy.html`: privacy policy based on the app's current local storage and Screen Time behavior.
- `website/styles.css`: shared responsive styling, keyboard focus, and dark appearance.
- `website/assets/app-icon.png`: a copy of the current app icon.

The user explicitly selected `liyufeiat010@gmail.com` as the public contact address. Never substitute another account or expose signing information when publishing.

**Current status:** The user requested local-only delivery on 2026-11-11. No repository creation, commits, pushes, or publication are authorized. The files and ZIP package are ready for later publication when explicitly requested.

## Intended hosting

Use a separate public GitHub repository named `nullptrpanic/daywell-support`. Publish only the files inside `website/` to its root. Do not copy the app repository, build artifacts, or private account information into the website repository.

The intended URLs are:

| App Store Connect field | URL |
| --- | --- |
| Support URL | `https://nullptrpanic.github.io/daywell-support/` |
| Privacy Policy URL | `https://nullptrpanic.github.io/daywell-support/privacy.html` |

**These addresses are deployment targets, not proof that the site is live.** Verify both anonymously after enabling Pages. The app's Settings links use the same base URL in `DaywellWebsite` in `App/SettingsView.swift`; publish the site before distributing that app build.

## First publication

1. Obtain the user's explicit permission to create/push the website commit, as required by the global working agreements. This is separate from the app repository, whose changes remain uncommitted.
2. Authenticate with GitHub using the supported connection or CLI flow. Never paste tokens into chat or save them in the website files.
3. Create the public `daywell-support` repository under the intended account, or verify ownership and contents if it already exists. Do not overwrite an unrelated repository.
4. Copy only `index.html`, `privacy.html`, `styles.css`, and `assets/app-icon.png` to that repository. Use a focused Conventional Commit such as `docs(site): add Daywell privacy and support pages`.
5. Open repository **Settings → Pages → Build and deployment**. Choose **Deploy from a branch**, select the website branch and **/(root)**, and save.
6. Wait for the Pages deployment to succeed. Verify both public pages, the stylesheet, and icon return successful responses without requiring a GitHub login.
7. Fill the verified URLs into App Store Connect. Upload an app build containing the new Settings links, with an incremented build number, and verify the links on a device.

## Maintenance

Edit source in `website/`, review privacy statements against actual code changes, and update the policy's date when its contents change. Publish the same source files to the dedicated site repository after authorization. If hosting changes, update both the policy's hosting section and `DaywellWebsite` before shipping the next app build.

The policy distinguishes local app data, optional Apple backup/diagnostics services, voluntarily sent support emails, and GitHub Pages visitor logs. Keep those distinctions accurate; a statement about no app telemetry does not mean the hosting or email providers never process personal data.

## Verification

- Check relative links and local assets; Pages serves this site under a project subpath.
- Check the support address and mail links on both pages.
- Check phone-width layout, readable text, keyboard navigation, and light/dark appearance.
- Keep preview outputs, ZIP archives, build logs, and DerivedData under `build/`.
- Compile the app after changing its Settings links.

References: [Apple privacy requirements](https://developer.apple.com/app-store/app-privacy-details/), [App Review Guidelines 5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage), [GitHub Pages setup](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site).

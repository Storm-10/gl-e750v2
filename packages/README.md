# Custom OpenWrt Packages

Put custom package feed content here if you want to use the `Build Packages (SDK)` workflow.

Expected layout:

```text
packages/
  my-package/
    Makefile
    files/
    patches/
```

The SDK workflow only makes sense when at least one package Makefile exists below this directory.

This repository already vendors:

- `amneziawg-tools`
- `kmod-amneziawg`
- `luci-proto-amneziawg`
- `luci-app-gl-e750`: GL-E750 cards, presets and translations for luci-app-5gmodem (its extension hooks)
- `luci-app-epm`

Source:

- https://github.com/Slava-Shchipunov/awg-openwrt
- https://github.com/stich86/luci-app-epm

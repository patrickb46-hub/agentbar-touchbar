APP      := AgentBar
BUNDLE   := build/$(APP).app
# 默认装到系统的「应用程序」文件夹（访达里能直接看到）；没权限时可以
# make install PREFIX=$HOME/Applications
PREFIX   ?= /Applications
SWIFT_FLAGS ?=
# LaunchServices 注册表工具：同名 bundle 有多份时，系统会随机挑一个启动
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 代码签名身份。有固定的自签证书就用它 —— TCC（辅助功能授权）是按
# 「指定要求」记账的，ad-hoc 签名每次编译指纹都变，授权就得重新给；
# 用同一张证书签，指定要求变成「bundle id + 证书根」，重装也不用重授权。
# 没证书就退回 ad-hoc（能跑，但每次重装都要重新授权）。
# 建证书：scripts/make_signing_cert.sh
SIGN_ID ?= $(shell security find-identity -p codesigning 2>/dev/null \
             | sed -n 's/.*"\(AgentBar Self Signed\)".*/\1/p' | head -1)
CODESIGN_ID = $(if $(SIGN_ID),$(SIGN_ID),-)

.PHONY: build bundle run install uninstall autostart clean preview test bench icon sign-cert

build:
	swift build -c release $(SWIFT_FLAGS)

test:
	swift build $(SWIFT_FLAGS)
	.build/debug/agentbar selftest --real

bench:
	swift build $(SWIFT_FLAGS)
	.build/debug/agentbar bench --iters 15 --today

bundle: build
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/release/agentbar $(BUNDLE)/Contents/MacOS/agentbar
	chmod 755 $(BUNDLE)/Contents/MacOS/agentbar 2>/dev/null || true
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/AgentBar.icns $(BUNDLE)/Contents/Resources/AgentBar.icns
	codesign --force --sign "$(CODESIGN_ID)" $(BUNDLE)
	@echo "签名：$(CODESIGN_ID)"
	@echo "bundled: $(BUNDLE)"

run: build
	.build/release/agentbar

install: bundle
	@mkdir -p $(PREFIX)/$(APP).app/Contents/MacOS 2>/dev/null || \
	  (echo "⚠️  没有 $(PREFIX) 的写权限，试试：make install PREFIX=$$HOME/Applications"; exit 1)
	cp .build/release/agentbar $(PREFIX)/$(APP).app/Contents/MacOS/agentbar
	chmod 755 $(BUNDLE)/Contents/MacOS/agentbar 2>/dev/null || true
	cp Resources/Info.plist $(PREFIX)/$(APP).app/Contents/Info.plist
	cp Resources/AgentBar.icns $(PREFIX)/$(APP).app/Contents/Resources/AgentBar.icns
	codesign --force --sign "$(CODESIGN_ID)" $(PREFIX)/$(APP).app
	@# 把编译目录那份从启动服务里摘掉，只让「应用程序」里这份对外可见，
	@# 否则双击时系统可能挑到 build/ 里的旧副本（表现就是「点了没反应」）
	-@$(LSREGISTER) -u "$(CURDIR)/$(BUNDLE)" >/dev/null 2>&1 || true
	-@$(LSREGISTER) -f "$(PREFIX)/$(APP).app" >/dev/null 2>&1 || true
	@echo "已安装到 $(PREFIX)/$(APP).app（访达 → 应用程序 里能看到）"
	@echo "双击它，或运行 open -a AgentBar 启动；启动后菜单栏会出现闪电图标"

uninstall:
	-launchctl bootout gui/$$(id -u) $(HOME)/Library/LaunchAgents/com.string255.agentbar.plist 2>/dev/null
	-rm -f $(HOME)/Library/LaunchAgents/com.string255.agentbar.plist
	-$(LSREGISTER) -u $(PREFIX)/$(APP).app >/dev/null 2>&1 || true
	-rm -rf $(PREFIX)/$(APP).app
	@echo "已卸载（~/.agentbar 里的配置和日志保留，手动删即可）"

autostart: install
	@mkdir -p $(HOME)/Library/LaunchAgents
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>com.string255.agentbar</string>' \
	  '  <key>ProgramArguments</key><array><string>$(PREFIX)/$(APP).app/Contents/MacOS/agentbar</string></array>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>StandardErrorPath</key><string>$(HOME)/.agentbar/launchd.err.log</string>' \
	  '</dict></plist>' \
	  > $(HOME)/Library/LaunchAgents/com.string255.agentbar.plist
	-launchctl bootout gui/$$(id -u) $(HOME)/Library/LaunchAgents/com.string255.agentbar.plist 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/com.string255.agentbar.plist
	@echo "已设置登录自启"

preview:
	swift build $(SWIFT_FLAGS)
	.build/debug/agentbar render --multi --width 680 --out docs/preview-multi.png
	.build/debug/agentbar render --live --state waiting_approval --tool Edit --elapsed 12 --width 680 --out docs/preview-approval.png
	.build/debug/agentbar render --idle --width 680 --out docs/preview-idle.png
	.build/debug/agentbar render --multi --width 680 --theme paper --out docs/preview-paper.png
	.build/debug/agentbar panel --out docs/preview-panel.png

sign-cert:
	./scripts/make_signing_cert.sh

icon:
	@mkdir -p Resources
	swift scripts/make_icon.swift /tmp/agentbar-icon-1024.png
	@rm -rf /tmp/AgentBar.iconset && mkdir -p /tmp/AgentBar.iconset
	@for s in 16 32 128 256 512; do \
	  sips -z $$s $$s /tmp/agentbar-icon-1024.png --out /tmp/AgentBar.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  d=$$((s*2)); \
	  sips -z $$d $$d /tmp/agentbar-icon-1024.png --out /tmp/AgentBar.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	@cp /tmp/agentbar-icon-1024.png /tmp/AgentBar.iconset/icon_512x512@2x.png
	iconutil -c icns /tmp/AgentBar.iconset -o Resources/AgentBar.icns
	@echo "已生成 Resources/AgentBar.icns"

clean:
	rm -rf .build build

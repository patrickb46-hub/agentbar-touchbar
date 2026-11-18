APP      := AgentBar
BUNDLE   := build/$(APP).app
PREFIX   ?= $(HOME)/Applications
SWIFT_FLAGS ?=

.PHONY: build bundle run install uninstall autostart clean preview

build:
	swift build -c release $(SWIFT_FLAGS)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/release/agentbar $(BUNDLE)/Contents/MacOS/agentbar
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)
	@echo "bundled: $(BUNDLE)"

run: build
	.build/release/agentbar

install: bundle
	mkdir -p $(PREFIX)
	rm -rf $(PREFIX)/$(APP).app
	cp -R $(BUNDLE) $(PREFIX)/$(APP).app
	@echo "已安装到 $(PREFIX)/$(APP).app，双击或在终端运行 open -a AgentBar 启动"

uninstall:
	-launchctl bootout gui/$$(id -u) $(HOME)/Library/LaunchAgents/com.string255.agentbar.plist 2>/dev/null
	-rm -f $(HOME)/Library/LaunchAgents/com.string255.agentbar.plist
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

clean:
	rm -rf .build build

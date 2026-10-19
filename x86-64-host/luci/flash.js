'use strict';
'require view';
'require dom';
'require form';
'require rpc';
'require fs';
'require ui';

const isReadonlyView = !L.hasViewPermission();

const callAbStatus = rpc.declare({
	object: 'luci.ab',
	method: 'status',
	expect: { '': { is_ab: false } }
});

const callAbSwitch = rpc.declare({
	object: 'luci.ab',
	method: 'switch',
	params: [ 'target', 'permanent', 'reboot' ],
	expect: { code: 1, output: '' }
});

const callAbBootOk = rpc.declare({
	object: 'luci.ab',
	method: 'bootok',
	expect: { code: 1, output: '' }
});

const callAbValidateImage = rpc.declare({
	object: 'luci.ab',
	method: 'validate_image',
	params: [ 'path' ],
	expect: { valid: false, message: '' }
});

const callAbStartUpgrade = rpc.declare({
	object: 'luci.ab',
	method: 'start_upgrade',
	params: [ 'path', 'migrate' ],
	expect: { code: 1 }
});

const callAbUpgradeLog = rpc.declare({
	object: 'luci.ab',
	method: 'upgrade_log',
	expect: { status: 'idle', log: '' }
});

const callAbReboot = rpc.declare({
	object: 'luci.ab',
	method: 'reboot',
	expect: { status: 'rebooting' }
});

const mapdata = { actions: {}, config: {} };

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(callAbStatus(), { is_ab: false }),
			fs.trimmed('/proc/sys/kernel/hostname'),
			fs.trimmed('/proc/mtd'),
			fs.trimmed('/proc/partitions'),
			fs.trimmed('/proc/mounts')
		]);
	},

	handleBackup(ev) {
		const form = E('form', {
			method: 'post',
			action: L.env.cgi_base + '/cgi-backup',
			enctype: 'application/x-www-form-urlencoded'
		}, E('input', { type: 'hidden', name: 'sessionid', value: rpc.getSessionID() }));
		ev.currentTarget.parentNode.appendChild(form);
		form.submit();
		form.parentNode.removeChild(form);
	},

	handleFirstboot(ev) {
		if (!confirm(_('Do you really want to erase all settings?')))
			return;

		ui.showModal(_('Erasing...'), [
			E('p', { 'class': 'spinning' }, _('The system is erasing the configuration partition now and will reboot itself when finished.'))
		]);

		fs.exec('/sbin/firstboot', [ '-r', '-y' ]);
		ui.awaitReconnect('10.0.0.1', 'immortalwrt.lan');
	},

	handleRestore(ev) {
		return ui.uploadFile('/tmp/backup.tar.gz', ev.target).then(L.bind(function(btn, res) {
			btn.firstChild.data = _('Checking archive…');
			return fs.exec('/bin/tar', [ '-tzf', '/tmp/backup.tar.gz' ]);
		}, this, ev.target)).then(L.bind(function(btn, res) {
			if (res.code != 0) {
				ui.addNotification(null, E('p', _('The uploaded backup archive is not readable')));
				return fs.remove('/tmp/backup.tar.gz');
			}

			ui.showModal(_('Apply backup?'), [
				E('p', _('The uploaded backup archive appears to be valid and contains the files listed below. Press "Continue" to restore the backup and reboot, or "Cancel" to abort the operation.')),
				E('pre', {}, [ res.stdout ]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.createHandlerFn(this, function() {
							return fs.remove('/tmp/backup.tar.gz').finally(ui.hideModal);
						})
					}, [ _('Cancel') ]),
					' ',
					E('button', {
						'class': 'btn cbi-button-action important',
						'click': ui.createHandlerFn(this, 'handleRestoreConfirm', btn)
					}, [ _('Continue') ])
				])
			]);
		}, this, ev.target)).catch(function(e) {
			ui.addNotification(null, E('p', e.message));
		}).finally(L.bind(function(btn) {
			btn.firstChild.data = _('Upload archive...');
		}, this, ev.target));
	},

	handleRestoreConfirm(btn) {
		return fs.exec('/sbin/sysupgrade', [ '--restore-backup', '/tmp/backup.tar.gz' ]).then(L.bind(function(btn, res) {
			if (res.code != 0) {
				ui.addNotification(null, [
					E('p', _('The restore command failed with code %d').format(res.code)),
					res.stderr ? E('pre', {}, [ res.stderr ]) : ''
				]);
				L.raise('Error', 'Unpack failed');
			}
			btn.firstChild.data = _('Rebooting…');
			return fs.exec('/sbin/reboot');
		}, this, btn)).then(function() {
			ui.showModal(_('Rebooting…'), [
				E('p', { 'class': 'spinning' }, _('The system is rebooting now. Please wait a few moments...'))
			]);
			ui.awaitReconnect(window.location.host, '10.0.0.1', 'immortalwrt.lan');
		}).catch(function(e) {
			ui.addNotification(null, E('p', e.message));
		}).finally(function() {
			btn.firstChild.data = _('Upload archive...');
		});
	},

	// 手动切换活动槽
	handleSwitchSlot(targetSlot) {
		const body = [
			E('p', {}, _('您确定要将引导槽切换至 <strong>槽 %s</strong> 吗？').format(targetSlot)),
			E('div', { 'class': 'alert-message info' }, [
				E('p', {}, _('<strong>安全防护保障机制：</strong>')),
				E('ul', {}, [
					E('li', {}, _('本次切换采用 <strong>一次性试跑 (next_entry)</strong> 模式；')),
					E('li', {}, _('新槽启动后通过网络可达性与系统检查，自动标记健康 (boot_ok=1)；')),
					E('li', {}, _('若目标槽内核异常或网络无法连通，GRUB 引导器将在连续 2 次重试后 <strong>自动无缝回滚回当前槽</strong>，无需串口插线！'))
				])
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'click': ui.hideModal
				}, [ _('取消') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, function() {
						ui.showModal(_('正在切换并重启...'), [
							E('p', { 'class': 'spinning' }, _('正在写入 GRUB 环境变量并重启系统...'))
						]);
						return callAbSwitch(targetSlot, false, true).then(function() {
							ui.awaitReconnect(window.location.host, '10.0.0.1', 'immortalwrt.lan');
						}).catch(function(err) {
							ui.hideModal();
							ui.addNotification(null, E('p', _('切换失败: %s').format(err.message)));
						});
					})
				}, [ _('确认切换并立即重启') ])
			])
		];
		ui.showModal(_('切换引导槽位 (A/B)'), body);
	},

	// 手动标记健康
	handleMarkBootOk() {
		ui.showModal(_('正在标记...'), [
			E('p', { 'class': 'spinning' }, _('正在将 boot_ok=1 写入 grubenv...'))
		]);
		return callAbBootOk().then(function(res) {
			ui.hideModal();
			if (res.code === 0) {
				ui.addNotification(null, E('p', _('✅ 已成功将当前启动标记为健康 (boot_ok=1, bootcount=0)！')), 'info');
				window.location.reload();
			} else {
				ui.addNotification(null, E('p', _('❌ 标记失败: %s').format(res.output)));
			}
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', err.message));
		});
	},

	// A/B 固件上传与校验
	handleAbUpload(abInfo, ev) {
		const targetSlot = abInfo.target_slot || 'B';
		const btn = ev.target;
		btn.firstChild.data = _('上传中…');

		return ui.uploadFile('/tmp/firmware.bin', ev.target).then(L.bind(function(btn, reply) {
			btn.firstChild.data = _('校验镜像…');
			ui.showModal(_('校验固件镜像…'), [
				E('p', { 'class': 'spinning' }, _('正在校验上传的 x86 Combined 镜像结构与分区合法性...'))
			]);
			return callAbValidateImage('/tmp/firmware.bin').then(function(valRes) {
				return [ reply, valRes ];
			});
		}, this, btn)).then(L.bind(function(btn, [ reply, valRes ]) {
			const chkMigrate = E('input', { type: 'checkbox', checked: true });
			const body = [];

			body.push(E('div', { 'class': 'alert-message ' + (valRes.valid ? 'success' : 'danger') }, [
				E('strong', {}, valRes.valid ? _('✅ 镜像校验通过') : _('⚠️ 镜像校验异常')),
				E('p', {}, valRes.message)
			]));

			body.push(E('ul', { 'class': 'cbi-value-description' }, [
				E('li', {}, '文件大小: %1024.2mB (%d 字节)'.format(valRes.size || reply.size, valRes.size || reply.size)),
				valRes.md5 ? E('li', {}, 'MD5 校验和: ' + valRes.md5) : '',
				valRes.sha256 ? E('li', {}, 'SHA256: ' + valRes.sha256) : '',
				valRes.partitions ? E('li', {}, '分区结构: ' + valRes.partitions) : ''
			]));

			if (!valRes.valid) {
				body.push(E('div', { 'class': 'alert-message danger' }, [
					_('警告: 上传的文件不符合 x86 Combined SquashFS 镜像特征，继续写入可能导致目标槽无法引导！')
				]));
			}

			body.push(E('hr'));
			body.push(E('h4', {}, _('升级部署选项:')));
			body.push(E('p', {}, [
				E('label', { 'class': 'cbi-checkbox' }, [
					chkMigrate,
					' ',
					E('strong', {}, _('保留并迁移当前系统配置 (Overlay 迁移)')),
					E('br'),
					E('span', { 'class': 'cbi-value-description' }, _('推荐勾选：新槽将复制当前的网络、Docker 与服务配置；若不勾选，新槽将以纯净出厂状态启动。'))
				])
			]));

			body.push(E('div', { 'class': 'alert-message info' }, [
				_('新固件将写入 <strong>备用槽 (槽 %s)</strong>。写入完成后当前系统不受影响，您可随时安排重启切换。').format(targetSlot)
			]));

			const confirmBtn = E('button', {
				'class': 'btn cbi-button-action important',
				'click': ui.createHandlerFn(this, function() {
					return this.startAbUpgradeProgress(chkMigrate.checked, targetSlot);
				})
			}, [ _('开始写入备用槽 (Slot %s)').format(targetSlot) ]);

			if (!valRes.valid) {
				confirmBtn.disabled = true;
			}

			body.push(E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'click': ui.createHandlerFn(this, function() {
						return fs.remove('/tmp/firmware.bin').finally(ui.hideModal);
					})
				}, [ _('取消') ]),
				' ',
				confirmBtn
			]));

			ui.showModal(_('A/B 固件升级确认 (目标: 槽 %s)').format(targetSlot), body);
		}, this, btn)).catch(function(e) {
			ui.addNotification(null, E('p', e.message));
		}).finally(function() {
			btn.firstChild.data = _('选择固件镜像并上传...');
		});
	},

	// 实时轮询升级进度
	startAbUpgradeProgress(doMigrate, targetSlot) {
		const logPre = E('pre', {
			'style': 'height: 320px; overflow-y: auto; background: #1e1e1e; color: #d4d4d4; padding: 10px; font-family: monospace; font-size: 12px; border-radius: 4px;'
		}, [ _('正在准备 A/B 升级任务...\n') ]);

		const statusText = E('span', { 'class': 'spinning' }, _('正在写入目标槽 %s (请勿断电)...').format(targetSlot));
		const actionBox = E('div', { 'class': 'right', 'style': 'margin-top: 15px;' });

		ui.showModal(_('A/B 固件写入进行中...'), [
			E('p', {}, [ statusText ]),
			logPre,
			actionBox
		]);

		return callAbStartUpgrade('/tmp/firmware.bin', doMigrate).then(function(res) {
			if (res.code !== 0) {
				statusText.className = '';
				statusText.innerHTML = '<span style="color:red">❌ 启动升级任务失败: ' + (res.error || '未知错误') + '</span>';
				actionBox.appendChild(E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('关闭') ]));
				return;
			}

			const pollInterval = window.setInterval(function() {
				callAbUpgradeLog().then(function(logRes) {
					if (logRes.log) {
						logPre.textContent = logRes.log;
						logPre.scrollTop = logPre.scrollHeight;
					}

					if (logRes.status === 'success') {
						window.clearInterval(pollInterval);
						statusText.className = '';
						statusText.innerHTML = '<strong style="color:green; font-size: 14px;">🎉 固件已成功写入槽 ' + targetSlot + '！已设置下次重启尝试新固件。</strong>';

						actionBox.appendChild(E('button', {
							'class': 'btn',
							'click': function() {
								ui.hideModal();
								window.location.reload();
							}
						}, [ _('稍后手动重启') ]));
						actionBox.appendChild(E('span', {}, ' '));
						actionBox.appendChild(E('button', {
							'class': 'btn cbi-button-action important',
							'click': function() {
								ui.showModal(_('正在重启系统...'), [
									E('p', { 'class': 'spinning' }, _('系统正在重启并引导至槽 %s，请等待重新连接...').format(targetSlot))
								]);
								callAbReboot().then(function() {
									ui.awaitReconnect(window.location.host, '10.0.0.1', 'immortalwrt.lan');
								});
							}
						}, [ _('🔄 立即重启切换至槽 %s').format(targetSlot) ]));

					} else if (logRes.status === 'failed') {
						window.clearInterval(pollInterval);
						statusText.className = '';
						statusText.innerHTML = '<strong style="color:red; font-size: 14px;">❌ 固件写入失败，当前系统未受影响。</strong>';
						actionBox.appendChild(E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('关闭') ]));
					}
				});
			}, 1000);
		}).catch(function(err) {
			statusText.className = '';
			statusText.innerHTML = '<span style="color:red">异常: ' + err.message + '</span>';
			actionBox.appendChild(E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('关闭') ]));
		});
	},

	// 渲染 A/B 专属看板组件
	renderAbSection(abInfo) {
		const curSlot = abInfo.current_slot || 'A';
		const tgtSlot = abInfo.target_slot || 'B';
		const slotA = abInfo.slot_a || {};
		const slotB = abInfo.slot_b || {};
		const grub = abInfo.grubenv || {};

		const isSafe = (grub.boot_ok == '1');
		const bootCount = grub.bootcount || 0;

		const cardStyle = 'border: 1px solid #ddd; border-radius: 6px; padding: 15px; margin-bottom: 15px; background: #fafafa;';
		const activeBadge = '<span style="background: #28a745; color: white; padding: 3px 8px; border-radius: 12px; font-weight: bold; font-size: 12px;">✅ 运行中 (ACTIVE)</span>';
		const standbyBadge = '<span style="background: #17a2b8; color: white; padding: 3px 8px; border-radius: 12px; font-weight: bold; font-size: 12px;">💤 备用槽 (STANDBY)</span>';

		const container = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('🛡️ A/B 双槽固件运行与容灾看板')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('本机运行在单盘 A/B 双槽高可用架构下。升级时将新固件写入备用槽，重启通过 GRUB 状态机进行健康检验；若启动异常，系统将自动回滚回旧槽，杜绝升级变砖。')
			]),

			// 双槽对比卡片
			E('div', { 'style': 'display: flex; gap: 15px; flex-wrap: wrap; margin-bottom: 15px;' }, [
				// Slot A 卡片
				E('div', { 'style': 'flex: 1; min-width: 280px; ' + cardStyle + (curSlot === 'A' ? 'border-color: #28a745; background: #f6fff6;' : '') }, [
					E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;' }, [
						E('h4', { 'style': 'margin:0;' }, _('槽 A (Slot A)')),
						E('span', {}, curSlot === 'A' ? activeBadge : standbyBadge)
					]),
					E('p', { 'style': 'margin: 4px 0;' }, [ E('strong', {}, _('分区设备: ')), slotA.device || '/dev/sda3' ]),
					E('p', { 'style': 'margin: 4px 0; font-size: 11px; word-break: break-all;' }, [ E('strong', {}, 'PARTUUID: '), slotA.partuuid || '-' ]),
					E('p', { 'style': 'margin: 4px 0;' }, [
						E('strong', {}, _('内核镜像: ')),
						slotA.kernel_size ? '%1024.2mB (%s)'.format(slotA.kernel_size, slotA.kernel_time || '') : _('无')
					])
				]),

				// Slot B 卡片
				E('div', { 'style': 'flex: 1; min-width: 280px; ' + cardStyle + (curSlot === 'B' ? 'border-color: #28a745; background: #f6fff6;' : '') }, [
					E('div', { 'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;' }, [
						E('h4', { 'style': 'margin:0;' }, _('槽 B (Slot B)')),
						E('span', {}, curSlot === 'B' ? activeBadge : standbyBadge)
					]),
					E('p', { 'style': 'margin: 4px 0;' }, [ E('strong', {}, _('分区设备: ')), slotB.device || '/dev/sda4' ]),
					E('p', { 'style': 'margin: 4px 0; font-size: 11px; word-break: break-all;' }, [ E('strong', {}, 'PARTUUID: '), slotB.partuuid || '-' ]),
					E('p', { 'style': 'margin: 4px 0;' }, [
						E('strong', {}, _('内核镜像: ')),
						slotB.kernel_size ? '%1024.2mB (%s)'.format(slotB.kernel_size, slotB.kernel_time || '') : _('无')
					])
				])
			]),

			// 引导状态指示条
			E('div', { 'class': 'alert-message ' + (isSafe ? 'success' : 'warning'), 'style': 'display: flex; justify-content: space-between; align-items: center;' }, [
				E('div', {}, [
					E('strong', {}, isSafe ? _('✅ 引导状态：已标记健康 (Safe)') : _('⏳ 引导状态：试运行待确认 (Testing)')),
					E('span', { 'style': 'margin-left: 15px;' }, _('连续失败重试计数: <strong>%d / 2</strong>').format(bootCount)),
					grub.next_entry !== '' && grub.next_entry !== undefined ?
						E('span', { 'style': 'margin-left: 15px; color: #0056b3;' }, _('一次性引导目标: 槽 %s').format(grub.next_entry == '0' ? 'A' : 'B')) : ''
				]),
				E('div', {}, [
					!isSafe ? E('button', {
						'class': 'btn cbi-button-action',
						'style': 'margin-right: 8px;',
						'click': ui.createHandlerFn(this, 'handleMarkBootOk')
					}, [ _('✅ 立即确认健康 (标记 boot_ok)') ]) : '',
					E('button', {
						'class': 'btn cbi-button-neutral',
						'click': ui.createHandlerFn(this, 'handleSwitchSlot', tgtSlot)
					}, [ _('🔀 切换到备用槽 (%s) 并重启').format(tgtSlot) ])
				])
			]),

			// 固件升级区域
			E('div', { 'class': 'cbi-section', 'style': 'margin-top: 25px; padding-top: 15px; border-top: 1px dashed #ccc;' }, [
				E('h3', {}, _('🚀 A/B 双槽平滑升级 (写入备用槽 %s)').format(tgtSlot)),
				E('p', { 'class': 'cbi-value-description' }, [
					_('请上传 x86 Combined 固件镜像（支持 .img 或 .img.gz 格式，如 <code>immortalwrt-x86-64-generic-squashfs-combined*.img.gz</code>）。固件将自动写入备用槽，升级全程不影响当前网络运行。')
				]),
				E('div', { 'style': 'margin-top: 15px;' }, [
					E('button', {
						'class': 'btn cbi-button-action important',
						'click': ui.createHandlerFn(this, 'handleAbUpload', abInfo)
					}, [ _('选择固件镜像并上传...') ])
				])
			])
		]);

		return container;
	},

	render([ abInfo, hostname, procmtd, procpart, procmounts ]) {
		const isAbLayout = abInfo && abInfo.is_ab;
		let m, s, o, ss;

		m = new form.JSONMap(mapdata, _('Flash operations'));
		m.tabbed = true;
		m.readonly = isReadonlyView;

		// -------------------------------------------------------------
		// Tab 1: A/B 升级主面板 (如果处于 A/B 架构)
		// -------------------------------------------------------------
		if (isAbLayout) {
			s = m.section(form.NamedSection, 'actions', _('A/B 固件升级与容灾'));
			s.render = L.bind(function() {
				return this.renderAbSection(abInfo);
			}, this);
		} else {
			// 非 A/B 模式下的友好提示卡片
			s = m.section(form.NamedSection, 'actions', _('固件刷写 (单盘模式)'));
			s.render = L.bind(function() {
				return E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'alert-message warning' }, [
						E('h4', {}, _('⚠️ 当前设备未启用 A/B 双槽高可用布局')),
						E('p', {}, _('当前系统未检测到 A/B 引导环境（可能仍运行在临时 U 盘或单分区模式下）。')),
						E('p', {}, _('为彻底避免断电与固件升级变砖风险，建议使用 <code>ab-layout.sh</code> 将系统迁移铺设到内置 SSD 硬盘上。'))
					]),
					E('p', {}, _('如需按常规方式升级，请在终端使用官方镜像执行部署，或先完成 A/B 磁盘布局铺设。'))
				]);
			}, this);
		}

		// -------------------------------------------------------------
		// Tab 2: 配置备份与还原 (全量保留原生功能)
		// -------------------------------------------------------------
		s = m.section(form.NamedSection, 'backup', _('配置备份与恢复'));
		
		o = s.option(form.SectionValue, 'backup_actions', form.NamedSection, 'backup_actions', 'backup_actions',
			_('备份'), _('点击“生成备份”可下载当前软路由全部配置文件的 tar 归档。'));
		ss = o.subsection;
		o = ss.option(form.Button, 'dl_backup', _('下载备份'));
		o.inputstyle = 'action important';
		o.inputtitle = _('生成备份');
		o.onclick = this.handleBackup;

		o = s.option(form.SectionValue, 'restore_actions', form.NamedSection, 'restore_actions', 'restore_actions',
			_('恢复'), _('在此上传之前导出的备份压缩包以恢复配置；或点击“恢复出厂设置”清空当前 Overlay 数据。'));
		ss = o.subsection;

		o = ss.option(form.Button, 'reset', _('恢复出厂设置'));
		o.inputstyle = 'negative important';
		o.inputtitle = _('恢复出厂设置');
		o.onclick = this.handleFirstboot;

		o = ss.option(form.Button, 'restore', _('恢复备份'));
		o.inputstyle = 'action important';
		o.inputtitle = _('上传备份文件...');
		o.onclick = L.bind(this.handleRestore, this);

		// -------------------------------------------------------------
		// Tab 3: 自定义备份文件清单
		// -------------------------------------------------------------
		s = m.section(form.NamedSection, 'config', _('备份清单设置'),
			_('在此定义每次备份与 A/B 升级配置迁移时需要额外包含的文件与目录通配符模式。'));
		
		s.render = L.bind(function(view) {
			return form.NamedSection.prototype.render.apply(this, this.varargs(arguments, 1)).then(L.bind(function(node) {
				node.appendChild(E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-save',
						'click': ui.createHandlerFn(view, 'handleBackupSave', this.map),
						'disabled': isReadonlyView || null
					}, [ _('保存清单') ])
				]));
				return node;
			}, this));
		}, s, this);

		o = s.option(form.TextValue, 'editlist');
		o.forcewrite = true;
		o.rows = 20;
		o.load = function() {
			return L.resolveDefault(fs.read('/etc/sysupgrade.conf'), '');
		};

		return m.render();
	},

	handleBackupSave(m) {
		return m.save(function() {
			return fs.write('/etc/sysupgrade.conf', mapdata.config.editlist.trim().replace(/\r\n/g, '\n') + '\n');
		}).then(function() {
			ui.addNotification(null, E('p', _('配置已保存。')), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('保存失败: %s').format(e)));
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

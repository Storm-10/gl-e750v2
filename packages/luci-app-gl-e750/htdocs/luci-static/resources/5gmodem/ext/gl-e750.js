'use strict';
'require baseclass';
'require form';
'require fs';
'require ui';

/* GL-E750 display and gestures (mcu-switch) in luci-app-5gmodem "Buttons" and SMS settings.
   Hooks: luci-app-5gmodem docs/subsystems/extensions.md; backend: /usr/share/5gmodem/buttons.d/gl-e750.sh */

var MCU = '/usr/bin/mcu-switch';
var BSH = '/usr/share/5gmodem/buttons.sh';
var E750 = {};	// "gl_e750" of buttons.sh detect
var noMenu = false;	// presets of menu items: no menu in the menu

function has(services, s) { return (services || []).indexOf(s) >= 0; }

function bad(status, e) {
	status.className = 'tg-btn-status bad';
	status.textContent = String((e && e.message) || e);
}

function run(args) {	// buttons.sh verb, '{"ok":1}' expected
	return fs.exec(BSH, args).then(function(res) {
		var j = {};
		try { j = JSON.parse(res.stdout); } catch (e) {}
		if (!j.ok) { throw new Error(j.error || res.stderr || _('Save failed')); }
	});
}

function delBtn(click) {	// as buttons.js: trash icon
	var b = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-negative tg-btn-ico',
		'title': _('Delete'), 'aria-label': _('Delete'), 'click': click });
	b.innerHTML = '<svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g></svg>';
	return b;
}

// state picker as buttons.js segmented(): heads [state, label], show(state) on click
function stateSeg(heads, show) {
	var wrap = E('div', { 'class': 'tg-btn-seg', 'role': 'group' });
	heads.forEach(function(h, i) {
		var el = E('button', { 'type': 'button', 'class': i ? '' : 'on', 'aria-pressed': String(!i) }, h[1]);
		el.addEventListener('click', function() {
			wrap.querySelectorAll('button').forEach(function(x) { x.classList.remove('on'); x.setAttribute('aria-pressed', 'false'); });
			el.classList.add('on');
			el.setAttribute('aria-pressed', 'true');
			show(h[0]);
		});
		wrap.appendChild(el);
	});
	return wrap;
}

// sw: { on, panel } = enable toggle that shows/hides the panel
function swToggle(label, sw) {
	var t = E('span', { 'class': 'btnsw', 'role': 'switch', 'tabindex': '0', 'aria-label': label, 'title': _('Enable action') });
	var set = function(on) {
		sw.on = on;
		t.classList.toggle('on', on);
		t.setAttribute('aria-checked', on ? 'true' : 'false');
		sw.panel.style.display = on ? '' : 'none';
	};
	t.addEventListener('click', function() { set(!sw.on); });
	t.addEventListener('keydown', function(ev) {
		if (ev.key === ' ' || ev.key === 'Enter') { ev.preventDefault(); set(!sw.on); }
	});
	set(sw.on);
	return t;
}

function opt(s, name) {
	return s.children.filter(function(o) { return o.option === name; })[0];
}

return baseclass.extend({
	init: function(data) {
		E750 = data.gl_e750 || {};
		(data.buttons || []).forEach(function(b) { if (b.name === 'power') { b.label = _('Long press'); } });
		if (!document.getElementById('gl-e750-css')) {
			document.head.appendChild(E('style', { 'id': 'gl-e750-css' },
				'.btnsw[role=switch]{cursor:pointer}.btnsw[role=switch]:focus-visible{outline:2px solid var(--tg-accent);outline-offset:2px}' +
				'.e750en{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:10px;font-size:12.5px}' +
				'.e750help{flex:1 1 18em}.e750list:empty{display:none}' +
				'.e750row{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:3px 0;border:2px solid transparent;border-width:2px 0}' +
				'.e750row .btncmd{flex:1 1 14em;min-width:0}.e750row .btncmd .cbi-value-description{display:none!important}' +
				'.e750row>*{margin:0!important}.e750row.dragging{opacity:.5}.e750row .drag-handle{cursor:move;user-select:none;-webkit-user-select:none}' +
				'.e750row.drag-over-above{border-top-color:var(--tg-accent)}.e750row.drag-over-below{border-bottom-color:var(--tg-accent)}'));
		}
	},

	presets: function(kind, services) {
		if (kind === 'conditional') {
			return [
				{ label: _('Toggle Standby mode'), cmd: MCU + ' standby' }
			];
		}
		var l = [];
		if (has(services, 'awg-control')) {
			l.push({ label: _('AmneziaWG full tunnel'), cmd: MCU + ' awg on_full',
				help: _('Sets AmneziaWG to full tunnel: configured interface started if down, all remote traffic routed via AmneziaWG.') });
			l.push({ label: _('AmneziaWG split tunnel'), cmd: MCU + ' awg on_split',
				help: _('Sets AmneziaWG to split tunnel: configured interface started if down, only traffic to subnets listed in /etc/split-routes/*.lst files routed via AmneziaWG.') });
			l.push({ label: _('Stop AmneziaWG'), cmd: MCU + ' awg off' });
		}
		if (has(services, 'passwall2')) {
			l.push({ label: _('Start Passwall2'), cmd: MCU + ' pw on' });
			l.push({ label: _('Stop Passwall2'), cmd: MCU + ' pw off' });
		}
		l.push({ label: _('Show SMS'), cmd: MCU + ' sms',
			help: _('Show SMS on GL-E750 display. Next page by switch flip. Long press offers to mark all messages read, or exits if none is unread. Additional settings in "Inbox"') });
		l.push({ label: _('Show Metrics'), cmd: MCU + ' metrics',
			help: _('Output system metrics on GL-E750 display: bandwidth via WAN interface, number of connections, load, CPU usage, memory available. Second screen: RSRP, RSRQ, SINR, RSSI of the signal. Change screen by switch flip. Exit by long press or automatically after 10 min.') });
		if (!noMenu) {
			l.push({ label: _('Show Menu'), cmd: MCU + ' menu',
				help: _("Show menu on GL-E750 display. Next item by switch flip, run selected item by long press. Exit by 'EXIT menu' item or automatically after 20 s without input. Items are set in 'GL-E750 Menu'.") });
		}
		return l;
	},

	// slide switch: ON / OFF / double flip, each with an enable toggle; power button: long press. Layout of buttons.js cards
	buttonCard: function(b, leds, services, onDelete, api) {
		var isLong = (b.name === 'power');
		if (!isLong && b.name !== 'BTN_0') { return null; }

		var heads = isLong ? [ [ 'pressed', _('Long press'), _('Hold right button for 3 s.') ] ] : [
			[ 'pressed', _('Switch ON'), '' ],
			[ 'released', _('Switch OFF'), '' ],
			[ 'double', _('Double flip'), _('Flip switch and back to original position within the interval.') ] ];
		var card = E('div', { 'class': 'cbi-section tg-btn-card', 'data-btn': b.name });
		var status = api.saveStatus();
		var en = {}, wraps = {};

		var panels = heads.map(function(h, i) {
			var p = api.statePanel(b, leds, h[0], services), line = [];
			if (!isLong) {
				en[h[0]] = { on: (E750.en || {})[h[0]] === '1', panel: p.node };
				line.push(swToggle(h[1], en[h[0]]), E('span', {}, _('Enable action')));
			}
			if (h[2]) { line.push(E('span', { 'class': 'tg-btn-muted e750help' }, h[2])); }
			wraps[h[0]] = E('div', { 'style': i ? 'display:none' : '' }, [ E('div', { 'class': 'e750en' }, line), p.node ]);
			return [ h[0], p ];
		});

		var top = [ E('h3', { 'class': 'tg-btn-title' }, [
			E('span', {}, [ b.label || b.name ]),
			E('span', { 'class': 'tg-proto-badge', 'title': b.name }, b.type === 'switch' ? _('switch') : _('button')) ]),
			E('span', { 'class': 'tg-btn-grow' }) ];
		if (!isLong) {
			top.push(stateSeg(heads, function(st) {
				Object.keys(wraps).forEach(function(k) { wraps[k].style.display = (k === st) ? '' : 'none'; });
			}));
		}
		top.push(delBtn(ui.createHandlerFn(this, function() {
			return api.delBinding(b.name).then(function() {
				if (card.parentNode) { card.parentNode.removeChild(card); }
				if (onDelete) { onDelete(b.name); }
			});
		})));
		card.appendChild(E('div', { 'class': 'tg-btn-top' }, top));
		heads.forEach(function(h) { card.appendChild(wraps[h[0]]); });

		var gest = null, foot = [];
		if (!isLong) {
			gest = E('input', { 'type': 'number', 'class': 'cbi-input-text tg-btn-dbc', 'min': '1', 'max': '5', 'step': '1',
				'aria-label': _('Interval, s'), 'value': E750.gest || '2' });
			foot.push(E('span', {}, _('Interval, s')), gest, E('span', { 'class': 'tg-btn-muted e750help' },
				_('Time to flip switch back for a double flip, 1-5 s. Longer: double flip is easier, but switch ON/OFF actions start later.')));
		} else {
			foot.push(E('span', { 'class': 'tg-btn-grow' }));
		}

		foot.push(status, E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function() {
				if (gest && !/^[1-5]$/.test(gest.value)) { bad(status, _('Interval: whole seconds 1-5')); return; }
				var f = [ 'debounce=' ], calls = [];	// no delay between repeats: gesture timing is in mcu-switch
				panels.forEach(function(pair) {
					var st = pair[0], v = pair[1].getVals();
					f.push('ct_' + st + '=' + (v.ct || ''), st + '=' + (v.cmd || ''));
					if (v.ct === 'conditional') {
						f.push('leds_on_' + st + '=' + (v.onLeds || ''), 'leds_off_' + st + '=' + (v.offLeds || ''));
					} else {
						f.push('leds_' + st + '=' + (v.simpleLeds || ''));
					}
					if (en[st]) { calls.push([ 'e750en', st, en[st].on ? '1' : '0' ]); }
				});
				calls.unshift([ 'save', b.name ].concat(f));
				if (gest) { calls.push([ 'e750gest', gest.value ]); }
				calls.push([ 'e750lpg' ]);	// mcu-switch: mirror to /etc/config/mcu, long press frame
				return calls.reduce(function(p, a) { return p.then(function() { return run(a); }); }, Promise.resolve())
					.then(function() { api.flashSaved(status); }, function(e) { bad(status, e); });
			}) }, _('Save')));
		card.appendChild(E('div', { 'class': 'tg-btn-foot' }, foot));
		return card;
	},

	// "GL-E750 Menu": items of mcu-switch menu in display order (mcu.menu.item); "EXIT menu" is added last by mcu-switch
	menuCard: function(api) {
		var status = api.saveStatus();
		var services = fs.exec(BSH, [ 'services' ]).then(function(res) {	// as buttons.js: presets depend on them
			try { return JSON.parse(res.stdout).services || []; } catch (e) { return []; }
		}).catch(function() { return []; });
		var list = E('div', { 'class': 'e750list' });
		var touch = ('ontouchstart' in window);
		var dragged = null;

		function clearMarks() {
			list.querySelectorAll('.drag-over-above,.drag-over-below').forEach(function(r) {
				r.classList.remove('drag-over-above', 'drag-over-below');
			});
		}
		function mark(row, y) {	// drop target: above or below the middle of the row, as LuCI tables
			clearMarks();
			if (!row || row === dragged) { return; }
			var b = row.getBoundingClientRect();
			row.classList.add(y < b.top + b.height / 2 ? 'drag-over-above' : 'drag-over-below');
		}
		function end(move) {
			var t = list.querySelector('.drag-over-above,.drag-over-below');
			if (move && t && dragged) { list.insertBefore(dragged, t.classList.contains('drag-over-above') ? t : t.nextSibling); }
			clearMarks();
			if (dragged) { dragged.classList.remove('dragging'); }
			dragged = null;
		}
		list.addEventListener('dragover', function(ev) {
			if (!dragged) { return; }
			ev.preventDefault();
			ev.dataTransfer.dropEffect = 'move';
			mark(ev.target.closest('.e750row'), ev.clientY);
		});
		list.addEventListener('drop', function(ev) { ev.preventDefault(); end(true); });

		function addRow(svc, ct, cmd) {
			noMenu = true;
			var p = api.statePanel({ ct_item: ct, cmd_item: cmd }, [], 'item', svc);
			noMenu = false;
			var c = p.node.querySelector('.btncmd'), hd = c.querySelector('.btnterm-hd');
			if (hd) { hd.parentNode.removeChild(hd); }
			var row = E('div', { 'class': 'e750row' });
			var handle = E('button', { 'type': 'button', 'title': _('Drag to reorder'), 'class': 'cbi-button drag-handle',
				'draggable': touch ? 'false' : 'true' }, '☰');
			if (touch) {
				handle.addEventListener('touchmove', function(ev) {
					var t = ev.touches[0], el = document.elementFromPoint(t.clientX, t.clientY);
					ev.preventDefault();
					dragged = row;
					row.classList.add('dragging');
					mark(el && el.closest('.e750row'), t.clientY);
				}, { passive: false });
				handle.addEventListener('touchend', function() { end(true); });
				handle.addEventListener('touchcancel', function() { end(false); });
			} else {
				handle.addEventListener('dragstart', function(ev) {
					dragged = row;
					row.classList.add('dragging');
					ev.dataTransfer.effectAllowed = 'move';
					ev.dataTransfer.setData('text/plain', '');
					var r = row.getBoundingClientRect();   // image held where the pointer grabbed it: on the handle
					ev.dataTransfer.setDragImage(row, ev.clientX - r.left, ev.clientY - r.top);
				});
				handle.addEventListener('dragend', function() { end(false); });
			}
			row.e750vals = p.getVals;
			row.appendChild(handle);
			row.appendChild(p.node.querySelector('.tg-btn-seg'));	// command type: Simple / Conditional
			row.appendChild(c);
			row.appendChild(delBtn(function() { list.removeChild(row); }));
			list.appendChild(row);
		}
		services.then(function(svc) { (E750.menu || []).forEach(function(m) { addRow(svc, m[0], m[1]); }); });

		return E('div', { 'class': 'cbi-section tg-btn-card' }, [
			E('div', { 'class': 'tg-btn-top' }, [
				E('h3', { 'class': 'tg-btn-title' }, E('span', {}, _('GL-E750 Menu'))),
				E('span', { 'class': 'tg-btn-grow' }),
				E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-add',
					'click': function() { services.then(function(svc) { addRow(svc, 'simple', ''); }); } }, '+ ' + _('New item')) ]),
			E('div', { 'class': 'tg-btn-muted' },
				_("Items of 'Show Menu' on the display; 'EXIT menu' is always last. Conditional item shows the action opposite to the current state, e.g. STANDBY ON.")),
			list,
			E('div', { 'class': 'tg-btn-foot' }, [
				E('span', { 'class': 'tg-btn-grow' }), status,
				E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function() {
						var items = Array.prototype.map.call(list.children, function(row) {
							var v = row.e750vals();
							return v.cmd.trim() ? v.ct + ' ' + v.cmd.trim() : '';
						}).filter(Boolean);
						return run([ 'e750menu' ].concat(items)).then(function() { api.flashSaved(status); }, function(e) { bad(status, e); });
					}) }, _('Save')) ])
		]);
	},

	// card after the buttons: "GL-E750 Menu"
	cards: function(data, api) {
		var f = document.createDocumentFragment();
		f.appendChild(this.menuCard(api));
		return f;
	},

	// SMS settings, group "receive": display options before 'bnumber', display as notification "LED"
	sms: function(group, s) {
		if (group !== 'receive') { return; }
		var n = s.children.length, o;

		o = s.option(form.Flag, 'mcu_sms', _('Output new message(s) to GL-E750 display'),
			_("Display is limited to Latin alphabet only. Translit will be used for Cyrillic symbols. E.g. Bud'te schastlivy!"));
		o.rmempty = false;

		o = s.option(form.Flag, 'mcu_last', _('Show only the last message'),
			_('When off all unread SMS will be displayed cycling in the order of time received starting with the most recent.'));
		o.rmempty = false;
		o.depends('mcu_sms', '1');

		o = s.option(form.Value, 'mcu_time', _('Time to display messages, seconds'),
			_('Timer restarts on input.'));
		o.datatype = 'range(1,900)';
		o.depends('mcu_sms', '1');

		var at = s.children.indexOf(opt(s, 'bnumber'));
		if (at >= 0) { Array.prototype.splice.apply(s.children, [ at, 0 ].concat(s.children.splice(n))); }

		if ((o = opt(s, 'ontopsms'))) {
			o.description = _('Show the new-message notification icon on the status overview page and GL-E750 display');
		}
		if ((o = opt(s, 'smsled'))) { o.value('mcu', _('Flash GL-E750 display')); }
	}
});

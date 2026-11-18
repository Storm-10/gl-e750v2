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

function sep() { return E('hr', { 'style': 'border:0;border-top:1px solid rgba(127,127,127,.2);margin:1.1em 0' }); }

// sw: { on, panel } = enable toggle that shows/hides the panel
function stateHead(label, help, sw) {
	var t = '';
	if (sw) {
		t = E('span', { 'class': 'btnsw' + (sw.on ? ' on' : ''), 'role': 'switch', 'tabindex': '0',
			'aria-checked': sw.on ? 'true' : 'false', 'aria-label': label, 'title': _('Enable action') });
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
	}
	return E('div', {}, [
		E('div', { 'class': 'btnstate-lbl' }, label),
		help ? E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:-.3em;margin-bottom:.45em' }, help) : '',
		t ]);
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
				'.e750row{display:flex;align-items:center;gap:.4em;padding:.15em 0;border:2px solid transparent;border-width:2px 0}' +
				'.e750row .btncmd{flex:1;min-width:0}.e750row .btncmd .cbi-value-description{display:none!important}' +
				'.e750row>button,.e750row .btnseg{flex:none;margin:0!important}.e750row.dragging{opacity:.5}' +
				'.e750row .btnseg{display:inline-grid;grid-template-columns:1fr 1fr}.e750row .btnseg button{font-weight:600}' +
				'.e750row.drag-over-above{border-top-color:#0069d6}.e750row.drag-over-below{border-bottom-color:#0069d6}'));
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
			help: _('Show SMS on GL-E750 display. Next page by switch flip. Long press offers to mark all messages read. Additional settings in "Inbox"') });
		l.push({ label: _('Show Metrics'), cmd: MCU + ' metrics',
			help: _('Output system metrics on GL-E750 display: bandwidth via WAN interface, number of connections, load, CPU usage, memory available. Second screen: RSRP, RSRQ, SINR, RSSI of the signal. Change screen by switch flip. Exit by long press or automatically after 10 min.') });
		if (!noMenu) {
			l.push({ label: _('Show Menu'), cmd: MCU + ' menu',
				help: _("Show menu on GL-E750 display. Next item by switch flip, run selected item by long press. Exit by 'EXIT menu' item or automatically after 20 s without input. Items are set in 'GL-E750 Menu'.") });
		}
		return l;
	},

	// slide switch: ON / OFF / double flip, each with an enable toggle; power button: long press
	buttonCard: function(b, leds, services, onDelete, api) {
		var isLong = (b.name === 'power');
		if (!isLong && b.name !== 'BTN_0') { return null; }

		var heads = isLong ? [ [ 'pressed', _('Long press'), _('Hold right button for 3 s.') ] ] : [
			[ 'pressed', _('Switch ON'), '' ],
			[ 'released', _('Switch OFF'), '' ],
			[ 'double', _('Double flip'), _('Flip switch and back to original position within the interval.') ] ];
		var card = E('div', { 'class': 'btncard' });
		var status = api.saveStatus();
		var en = {};

		card.appendChild(E('button', { 'class': 'btn cbi-button cbi-button-remove btncard-del',
			'click': ui.createHandlerFn(this, function() {
				return api.delBinding(b.name).then(function() {
					if (card.parentNode) { card.parentNode.removeChild(card); }
					if (onDelete) { onDelete(b.name); }
				});
			}) }, _('Delete')));

		var panels = heads.map(function(h, i) {
			var p = api.statePanel(b, leds, h[0], services);
			if (!isLong) { en[h[0]] = { on: (E750.en || {})[h[0]] === '1', panel: p.node }; }
			if (i) { card.appendChild(sep()); }
			card.appendChild(stateHead(h[1], h[2], en[h[0]]));
			card.appendChild(p.node);
			return [ h[0], p ];
		});

		var gest = null;
		if (!isLong) {
			gest = E('input', { 'type': 'number', 'class': 'cbi-input-text', 'min': '1', 'max': '5', 'step': '1',
				'style': 'width:5em', 'value': E750.gest || '2' });
			card.appendChild(E('div', { 'class': 'cbi-value', 'style': 'margin-top:.6em' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Interval, s')),
				E('div', { 'class': 'cbi-value-field' }, [ gest,
					E('div', { 'class': 'cbi-value-description' },
						_('Time to flip switch back for a double flip, 1-5 s. Longer: double flip is easier, but switch ON/OFF actions start later.')) ]) ]));
		}

		card.appendChild(E('div', { 'style': 'margin-top:.9em' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-save',
				'click': ui.createHandlerFn(this, function() {
					// no delay between repeats: gesture timing is in mcu-switch
					var ops = [ function() { return api.setField(b.name, 'debounce', ''); } ];
					if (gest) {
						if (!/^[1-5]$/.test(gest.value)) {
							status.textContent = _('Interval: whole seconds 1-5');
							status.style.color = '#e5484d';
							return;
						}
						ops.push(function() { return fs.exec(BSH, [ 'e750gest', gest.value ]); });
					}
					panels.forEach(function(pair) {
						var st = pair[0], v = pair[1].getVals();
						if (en[st]) {
							ops.push(function() { return fs.exec(BSH, [ 'e750en', st, en[st].on ? '1' : '0' ]); });
						}
						ops.push(function() { return api.setField(b.name, 'ct_' + st, v.ct); });
						ops.push(function() { return api.setField(b.name, st, v.cmd); });
						if (v.ct === 'conditional') {
							ops.push(function() { return api.setLeds(b.name, 'on_' + st, v.onLeds); });
							ops.push(function() { return api.setLeds(b.name, 'off_' + st, v.offLeds); });
						} else {
							ops.push(function() { return api.setLeds(b.name, st, v.simpleLeds); });
						}
					});
					return ops.reduce(function(p, mk) { return p.then(mk); }, Promise.resolve())
						.then(function() { api.flashSaved(status); });
				}) }, _('Save')), status ]));
		return card;
	},

	// "GL-E750 Menu": items of mcu-switch menu in display order (mcu.menu.item); "EXIT menu" is added last by mcu-switch
	menuCard: function(api) {
		var status = api.saveStatus();
		var services = fs.exec(BSH, [ 'services' ]).then(function(res) {	// as buttons.js: presets depend on them
			try { return JSON.parse(res.stdout).services || []; } catch (e) { return []; }
		}).catch(function() { return []; });
		var list = E('div', {});
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
				'style': 'cursor:move;user-select:none;-webkit-user-select:none', 'draggable': touch ? 'false' : 'true' }, '☰');
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
			row.appendChild(p.node.querySelector('.btnseg'));
			row.appendChild(c);
			row.appendChild(E('button', { 'type': 'button', 'class': 'btn cbi-button cbi-button-remove',
				'click': function() { list.removeChild(row); } }, _('Delete')));
			row.appendChild(handle);
			list.appendChild(row);
		}
		services.then(function(svc) { (E750.menu || []).forEach(function(m) { addRow(svc, m[0], m[1]); }); });

		return E('div', { 'class': 'btncard' }, [
			E('div', { 'class': 'btnstate-lbl' }, _('GL-E750 Menu')),
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:-.3em;margin-bottom:.6em' },
				_("Items of 'Show Menu' on the display; 'EXIT menu' is always last. Conditional item shows the action opposite to the current state, e.g. STANDBY ON.")),
			list,
			E('div', { 'style': 'margin-top:.9em' }, [
				E('button', { 'type': 'button', 'class': 'btn cbi-button cbi-button-add', 'style': 'margin-right:.4em',
					'click': function() { services.then(function(svc) { addRow(svc, 'simple', ''); }); } }, '+ ' + _('New item')),
				E('button', { 'class': 'btn cbi-button cbi-button-save',
					'click': ui.createHandlerFn(this, function() {
						var items = Array.prototype.map.call(list.children, function(row) {
							var v = row.e750vals();
							return v.cmd.trim() ? v.ct + ' ' + v.cmd.trim() : '';
						}).filter(Boolean);
						return fs.exec(BSH, [ 'e750menu' ].concat(items)).then(function(res) {
							var j = {};
							try { j = JSON.parse(res.stdout); } catch (e) {}
							if (!j.ok) { throw new Error(j.error || res.stderr || _('Save failed')); }
							api.flashSaved(status);
						}).catch(function(e) {
							status.textContent = String((e && e.message) || e);
							status.style.color = '#e5484d';
						});
					}) }, _('Save')), status ])
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

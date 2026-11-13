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
				'.btnsw[role=switch]{cursor:pointer}.btnsw[role=switch]:focus-visible{outline:2px solid var(--tg-accent);outline-offset:2px}'));
		}
	},

	presets: function(kind, services) {
		if (kind === 'conditional') {
			return [
				{ label: _('Toggle Standby mode'), cmd: MCU + ' standby' },
				{ label: _('Toggle Metrics'), cmd: MCU + ' metrics',
					help: _('Output system metrics on GL-E750 display: bandwidth via WAN interface, number of connections, load, CPU usage, memory available. Second screen: RSRP, RSRQ, SINR, RSSI of the signal. Change screen by switch flip. Exits automatically after 10 min.') }
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
			help: _('Show SMS on GL-E750 display. Additional settings in "Inbox"') });
		return l;
	},

	// slide switch: ON / OFF / double flip, each with an enable toggle; power button: long press
	buttonCard: function(b, leds, services, onDelete, api) {
		var isLong = (b.name === 'power');
		if (!isLong && b.name !== 'BTN_0') { return null; }

		var heads = isLong ? [ [ 'pressed', _('Long press'), _('Hold right button for 3 s.') ] ] : [
			[ 'pressed', _('Switch ON'), '' ],
			[ 'released', _('Switch OFF'), '' ],
			[ 'double', _('Double flip'), _('Flip switch and back to original position within 2 s.') ] ];
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

		card.appendChild(E('div', { 'style': 'margin-top:.9em' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-save',
				'click': ui.createHandlerFn(this, function() {
					// no delay between repeats: gesture timing is in mcu-switch
					var ops = [ function() { return api.setField(b.name, 'debounce', ''); } ];
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

	// "Show SMS mode": what the gestures do while SMS are on the display
	cards: function(data, api) {
		var acts = [
			[ 'page', _('Next page') ], [ 'next', _('Next message') ], [ 'prev', _('Previous message') ],
			[ 'replay', _('Replay message') ], [ 'read', _('Mark all read and exit') ], [ 'exit', _('Exit') ]
		];
		var status = api.saveStatus();
		var sels = [ [ 'flip', _('Switch flip') ], [ 'double', _('Double flip') ], [ 'long', _('Long press') ] ].map(function(r) {
			return [ r[0], r[1], E('select', { 'class': 'cbi-input-select' }, acts.map(function(a) {
				return E('option', { 'value': a[0], 'selected': E750[r[0]] === a[0] ? '' : null }, a[1]);
			})) ];
		});
		return E('div', { 'class': 'btncard' }, [
			E('div', { 'class': 'btnstate-lbl' }, _('Show SMS mode')),
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:-.3em;margin-bottom:.6em' },
				_("This mode also activates if configured in 'Inbox'. Button actions below apply only to this mode.")),
			E('div', {}, sels.map(function(s) {
				return E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, s[1]),
					E('div', { 'class': 'cbi-value-field' }, s[2]) ]);
			})),
			E('div', { 'style': 'margin-top:.9em' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-save',
					'click': ui.createHandlerFn(this, function() {
						return sels.reduce(function(p, s) {
							return p.then(function() { return fs.exec(BSH, [ 'smsmode', s[0], s[2].value ]); });
						}, Promise.resolve()).then(function() { api.flashSaved(status); });
					}) }, _('Save')), status ])
		]);
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
			_("Timer restarts on input. Configure actions in 'Buttons'."));
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

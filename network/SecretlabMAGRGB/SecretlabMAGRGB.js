export function Name() { return "Secretlab MAGRGB (Nanoleaf)"; }
export function Version() { return "1.0.0"; }
export function Type() { return "network"; }
export function Publisher() { return "local"; }
export function Size() { return [41, 1]; }
export function DefaultPosition() { return [0, 0]; }
export function DefaultScale() { return 8.0; }
export function DefaultComponentBrand() { return "CompGen"; }

/* global
controller:readonly
discovery:readonly
LightingMode:readonly
forcedColor:readonly
UpdateRate:readonly
ReverseDirection:readonly
TransitionTime:readonly
turnOffOnShutdown:readonly
hexToRgb:readonly
*/

export function ControllableParameters() {
	return [
		{ "property": "LightingMode",     "group": "settings", "label": "Lighting Mode", "type": "combobox", "values": ["Canvas", "Forced"], "default": "Canvas" },
		{ "property": "forcedColor",      "group": "settings", "label": "Forced Color", "min": "0", "max": "360", "type": "color", "default": "#009bde" },
		{ "property": "UpdateRate",       "group": "settings", "label": "Update rate", "type": "combobox", "values": ["10fps", "20fps", "30fps", "45fps"], "default": "30fps" },
		{ "property": "ReverseDirection", "group": "settings", "label": "Reverse direction (zone 0 is on the right)", "type": "boolean", "default": "true" },
		{ "property": "TransitionTime",   "group": "settings", "label": "Transition (x100ms, 0 = instant)", "type": "number", "min": "0", "max": "10", "default": "0" },
		{ "property": "turnOffOnShutdown","group": "settings", "label": "Turn strip OFF on shutdown", "type": "boolean", "default": "false" },
	];
}

/* =====================================================================================
 *  Measured facts about the NL72S2 (firmware 4.0.0, hardware 1.3.0)
 *
 *   - 41 addressable zones, panel IDs 0..40.
 *   - Panel ID 0 is at the RIGHT-hand end of the strip.
 *   - GET /panelLayout/* returns HTTP 500: not implemented on this 1D device,
 *     so the zone count cannot be discovered and is pinned per model below.
 *   - A frame containing ANY out-of-range panel ID is rejected in full, not
 *     partially applied. Never send more than ZONES entries.
 *   - extControl only updates the zones present in the frame; every other zone
 *     keeps its previous colour. We always send all 41, so this never bites.
 *   - PUT /effects with extControl v2 replies 204 and GET /effects/select then
 *     reads "*ExtControl*".
 * ===================================================================================== */

const MODEL_ZONES     = { "NL72S2": 41 };
const FALLBACK_ZONES  = 41;
const OPENAPI_PORT    = 16021;
const EXTCONTROL_PORT = 60222;
const BIG_ENDIAN      = 1;
const REARM_INTERVAL  = 10000;

/* Auth tokens are NEVER stored in this file. They live in SignalRGB own settings
 * store via service.saveSetting(), obtained either by auto-pairing or by pasting an
 * existing token into the plugin panel. Keep it that way - this repo is publishable. */

let MAGRGB;

/* =====================================================================================
 *  Device
 * ===================================================================================== */

class MagRgbDevice {
	constructor(ctrl) {
		this.ip         = ctrl.ip;
		this.port       = ctrl.port || OPENAPI_PORT;
		this.name       = ctrl.name;
		this.token      = ctrl.token;
		this.zones      = ctrl.zones || FALLBACK_ZONES;
		this.streamPort = ctrl.streamPort || EXTCONTROL_PORT;
		this.lastArm    = 0;
		this.lastFrame  = 0;
	}

	setupLeds() {
		const names = [];
		const positions = [];

		for (let i = 0; i < this.zones; i++) {
			names.push("Zone " + (i + 1));
			positions.push([i, 0]);
		}

		device.setSize([this.zones, 1]);
		device.setControllableLeds(names, positions);
	}

	frameInterval() {
		switch (UpdateRate) {
			case "10fps": return 100;
			case "20fps": return 50;
			case "45fps": return 22;
			default:      return 33;
		}
	}

	/* Hand every LED over to us. Exactly what Nanoleaf Desktop sends for this model. */
	armExtControl() {
		this.lastArm = Date.now();
		const url = "http://" + this.ip + ":" + this.port + "/api/v1/" + this.token + "/effects";
		Http.request("PUT", url, { write: { command: "display", animType: "extControl", extControlVersion: "v2" } }, (xhr) => {
			if (xhr.readyState !== 4) { return; }

			if (xhr.status !== 200 && xhr.status !== 204) {
				device.log("extControl arm failed, HTTP " + xhr.status);
			}
		});
	}

	/* extControl v2, big-endian:
	 *   uint16 panelCount
	 *   per panel: uint16 panelId, uint8 R, G, B, W, uint16 transitionTime  */
	buildFrame(shutdown) {
		const n  = this.zones;
		const tt = Math.max(0, Math.min(10, parseInt(TransitionTime, 10) || 0));
		const rev = (ReverseDirection !== false && ReverseDirection !== "false");
		const packet = [(n >> 8) & 0xFF, n & 0xFF];

		let forced = null;

		if (shutdown) { forced = [0, 0, 0]; }
		else if (LightingMode === "Forced") { forced = hexToRgb(forcedColor); }

		for (let i = 0; i < n; i++) {
			// canvas runs left -> right; panel 0 sits at the right-hand end
			const id = rev ? (n - 1 - i) : i;
			const c  = forced ? forced : device.color(i, 0);

			packet.push((id >> 8) & 0xFF, id & 0xFF);
			packet.push(c[0] & 0xFF, c[1] & 0xFF, c[2] & 0xFF, 0x00);
			packet.push((tt >> 8) & 0xFF, tt & 0xFF);
		}

		return packet;
	}

	sendFrame(shutdown = false) {
		const now = Date.now();

		if (!shutdown && now - this.lastFrame < this.frameInterval()) { return; }
		this.lastFrame = now;

		if (now - this.lastArm > REARM_INTERVAL) { this.armExtControl(); }

		udp.send(this.ip, this.streamPort, this.buildFrame(shutdown), BIG_ENDIAN);
	}

	setPower(on) {
		const url = "http://" + this.ip + ":" + this.port + "/api/v1/" + this.token + "/state";
		Http.request("PUT", url, { on: { value: on } }, () => {});
	}
}

export function Initialize() {
	device.setName(controller.name);
	device.addFeature("udp");
	device.setImageFromUrl("https://raw.githubusercontent.com/Pop-Code/Secretlab-MagRGB-SignalRGB-plugin/main/assets/icon.png");
	MAGRGB = new MagRgbDevice(controller);
	MAGRGB.setupLeds();
	MAGRGB.setPower(true);
	MAGRGB.armExtControl();
	device.log("MAGRGB ready: " + MAGRGB.zones + " zones @ " + MAGRGB.ip + ":" + MAGRGB.streamPort);
}

export function Render() {
	MAGRGB.sendFrame();
}

export function Shutdown(suspend) {
	MAGRGB.sendFrame(true);

	if (turnOffOnShutdown) { MAGRGB.setPower(false); }
}

/* =====================================================================================
 *  Discovery
 * ===================================================================================== */

export function DiscoveryService() {
	this.IconUrl = "https://raw.githubusercontent.com/Pop-Code/Secretlab-MagRGB-SignalRGB-plugin/main/assets/icon.png";
	this.MDns = ["_nanoleafapi._tcp.local."];

	this.Initialize = function () {
		service.log("Secretlab MAGRGB discovery starting");
		this.loadSaved();

	};

	this.isValidIP = function (ip) {
		return /^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}$/.test(ip);
	};

	this.Discovered = function (value) {
		service.log("mDNS record:");
		service.log(value);

		let ip = value.ip;

		if (!ip && value.addresses && value.addresses.length) { ip = value.addresses[0]; }
		if (!ip && this.isValidIP(value.hostname)) { ip = value.hostname; }
		if (!ip) { return; }

		this.addOrUpdate(ip, ip, value.name || ("Nanoleaf " + ip));
	};

	this.forceDiscover = function (ip) {
		if (!this.isValidIP(ip)) { service.log("not a valid IPv4: " + ip); return; }
		this.addOrUpdate(ip, ip, "Secretlab MAGRGB");
		this.saveDevice(ip);
	};

	/* Paste a token you already hold (e.g. from tools/magrgb-probe.ps1) instead of
	 * re-running the pairing window. Stored in SignalRGB's settings, never in this repo. */
	this.setToken = function (ip, token) {
		if (!this.isValidIP(ip)) { service.log("not a valid IPv4: " + ip); return; }
		if (!token || token.length < 8) { service.log("token looks too short, ignoring"); return; }

		service.saveSetting(ip, "token", token);
		this.addOrUpdate(ip, ip, "Secretlab MAGRGB");
		this.saveDevice(ip);

		const c = service.getController(ip);

		if (c !== undefined) { c.token = token; c.identify(); }

		service.log("Token stored for " + ip);
	};

	this.forceDelete = function (ip) {
		for (const c of service.controllers) {
			if (c.obj.ip === ip) { service.removeSetting(ip, "token"); service.removeController(c); }
		}

		const raw = service.getSetting("manual", "devices");

		if (raw) {
			service.saveSetting("manual", "devices", JSON.stringify(JSON.parse(raw).filter(x => x !== ip)));
		}
	};

	this.addOrUpdate = function (id, ip, name) {
		const existing = service.getController(id);

		if (existing === undefined) { service.addController(new MagRgbController(id, ip, name)); }
	};

	this.saveDevice = function (ip) {
		let list = [];
		const raw = service.getSetting("manual", "devices");

		if (raw) { try { list = JSON.parse(raw); } catch (e) { list = []; } }
		if (list.indexOf(ip) === -1) { list.push(ip); }

		service.saveSetting("manual", "devices", JSON.stringify(list));
	};

	this.loadSaved = function () {
		const raw = service.getSetting("manual", "devices");

		if (!raw) { return; }

		try {
			for (const ip of JSON.parse(raw)) { this.addOrUpdate(ip, ip, "Secretlab MAGRGB"); }
		} catch (e) { /* ignore */ }
	};

	this.Update = function () {
		for (const c of service.controllers) { c.obj.poll(); }
	};
}

/* =====================================================================================
 *  Controller
 * ===================================================================================== */

class MagRgbController {
	constructor(id, ip, name) {
		this.id         = id;
		this.ip         = ip;
		this.port       = OPENAPI_PORT;
		this.name       = name;
		this.streamPort = EXTCONTROL_PORT;
		this.zones      = 0;
		this.model      = "";
		this.announced  = false;
		this.lastPoll   = 0;
		this.pairLogged = false;
		this.token      = service.getSetting(id, "token");

		service.log("Controller: " + name + " @ " + ip + (this.token ? " (paired)" : " (needs pairing)"));

		if (this.token) { this.identify(); }
	}

	poll() {
		const now = Date.now();

		if (now - this.lastPoll < 3000) { return; }
		this.lastPoll = now;

		if (!this.token) { this.tryPair(); }
		else if (!this.zones) { this.identify(); }
	}

	/* Only succeeds inside the strip's 30 s authorization window, which on this model is
	 * opened over LTPDU (Nanoleaf Desktop -> Enable API -> Connect to API). */
	tryPair() {
		Http.request("POST", "http://" + this.ip + ":" + this.port + "/api/v1/new", null, (xhr) => {
			if (xhr.readyState !== 4) { return; }

			if (xhr.status === 200) {
				try {
					const token = JSON.parse(xhr.response).auth_token;

					if (token) {
						this.token = token;
						service.saveSetting(this.id, "token", token);
						service.log("Paired with " + this.ip);
						this.identify();
					}
				} catch (e) { service.log("pair response unparseable"); }
			} else if (!this.pairLogged) {
				this.pairLogged = true;
				service.log("Waiting for authorization window on " + this.ip + " (HTTP " + xhr.status + ")");
			}
		});
	}

	/* GET / works on this firmware; panelLayout does not, so the zone count comes from
	 * the model table. Try panelLayout anyway in case other models land here. */
	identify() {
		Http.request("GET", "http://" + this.ip + ":" + this.port + "/api/v1/" + this.token + "/", null, (xhr) => {
			if (xhr.readyState !== 4) { return; }

			if (xhr.status === 401 || xhr.status === 403) {
				service.log("Token rejected by " + this.ip + ", clearing");
				service.removeSetting(this.id, "token");
				this.token = undefined;

				return;
			}

			if (xhr.status !== 200) { return; }

			let zones = 0;

			try {
				const info = JSON.parse(xhr.response);
				this.model = info.model || "";

				if (info.name) { this.name = info.name; }

				const pd = info.panelLayout && info.panelLayout.layout
				         ? info.panelLayout.layout.positionData : null;

				if (pd && pd.length) { zones = pd.length; }
				if (!zones && MODEL_ZONES[this.model]) { zones = MODEL_ZONES[this.model]; }
			} catch (e) { /* fall through */ }

			this.zones = zones || FALLBACK_ZONES;
			service.log(this.name + " (" + this.model + "): " + this.zones + " zones");
			this.announce();
		});
	}

	announce() {
		if (this.announced) { return; }
		this.announced = true;
		service.updateController(this);
		service.announceController(this);
		service.log("Announced " + this.name);
	}
}

/* =====================================================================================
 *  HTTP
 * ===================================================================================== */

class Http {
	static request(method, url, body, callback, async = true) {
		const xhr = new XMLHttpRequest();
		xhr.open(method, url, async);
		xhr.setRequestHeader("Accept", "application/json");
		xhr.setRequestHeader("Content-Type", "application/json");
		xhr.onreadystatechange = callback.bind(null, xhr);

		if (body === null || body === undefined) { xhr.send(); }
		else { xhr.send(JSON.stringify(body)); }
	}
}

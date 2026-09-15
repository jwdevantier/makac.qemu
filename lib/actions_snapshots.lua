-- pkgs:qemu/actions_snapshots — internal implementation of qemu:savevm
-- (design/snapshots.md). A snapshot is the VM's full live state baked into
-- its disk image under a tag, via QMP `snapshot-save` on the VM's writable
-- block devices; the guest is quiesced for the capture and keeps running
-- after. The snapshot survives the VM dying and travels with the image.

local handlelib = require("pkgs:qemu/handle")
local actions_qmp = require("pkgs:qemu/actions_qmp")

local M = {}

local function fmt_probe(p)
	return ("alive=%s running=%s runstate=%s pid=%s qmp_connected=%s"):format(
		tostring(p.alive), tostring(p.running), tostring(p.runstate),
		tostring(p.pid), tostring(p.qmp_connected))
end

-- default_tag(): the timestamped default (snapshots.md) — wall-clock
-- timestamp plus randomness so repeats do not clash.
local function default_tag()
	return ("%s-%s"):format(os.date("!%Y%m%d-%H%M%S"), makac.random_hex(4))
end

-- send1(client, h, cmd, action) -> result: one command, error reply = step
-- failure naming the command and the QMP error description (snapshots.md).
local function send1(client, h, cmd, action)
	local ok, one = pcall(client.send, client, { cmd }, { timeout_s = 60 })
	if not ok then
		error(("qemu:%s: VM '%s': %s"):format(action, h.name, tostring(one)), 0)
	end
	local result = one[1]
	if type(result) == "table" and result.error ~= nil then
		error(("qemu:%s: VM '%s': command '%s' failed: %s (%s)"):format(
			action, h.name, cmd.execute,
			tostring(result.error.desc), tostring(result.error.class)), 0)
	end
	return result
end

-- writable_devices(client, h): enumerate the VM's writable block devices
-- via query-block, resolving each to its BLOCK NODE NAME — not the
-- BlockBackend/qdev id from `device` (an id-less `-drive if=virtio` is
-- reported as "virtio0", which snapshot-save cannot resolve:
-- bdrv_find_node(devices->value), "No block device node 'virtio0'").
-- snapshot-save snapshots ALL listed devices: `vmstate` (where the VM
-- state goes) is one of them — per QEMU's own QMP example, the vmstate
-- device is ALSO a member of `devices` (`vmstate: "disk0", devices:
-- ["disk0", "disk1"]`), which keeps `devices` non-empty: an empty Lua
-- table would JSON-encode as an OBJECT `{}` and QMP would reject the
-- required `['str']` array. An empty/unwritable device (no `inserted`,
-- or inserted.ro) carries no state. No writable device at all is a step
-- failure (requirements, snapshots.md).
local function writable_devices(client, h, action)
	local result = send1(client, h, { execute = "query-block" }, action)
	local blocks = result["return"]
	if type(blocks) ~= "table" then
		error(("qemu:%s: VM '%s': query-block answered unexpectedly (no device list)")
			:format(action, h.name), 0)
	end
	local writable = {}
	for _, b in ipairs(blocks) do
		if type(b) == "table" then
			local ins = b.inserted
			-- explicit ro=false only: a block info without `inserted` is
			-- an empty drive; `ro` absent is not proven writable
			if type(ins) == "table" and ins.ro == false then
				-- prefer the graph node name (snapshot-save resolves names
				-- via bdrv_find_node); fall back to the backend id — a
				-- `-drive if=none,id=...` IS the node-less backend name and
				-- QEMU accepts those too
				local node = type(ins["node-name"]) == "string" and ins["node-name"] or nil
				local dev = type(b.device) == "string" and b.device ~= "" and b.device or nil
				local name = node or dev
				if name == nil then
					error(("qemu:%s: VM '%s': a writable device has neither a node name nor a device id — cannot snapshot")
						:format(action, h.name), 0)
				end
				writable[#writable + 1] = name
			end
		end
	end
	if #writable == 0 then
		error(("qemu:%s: VM '%s': no writable block device to snapshot "
			.. "(internal snapshots live in writable devices; requirement, snapshots.md)")
			:format(action, h.name), 0)
	end
	return writable
end

-- wait_for_job(client, h, job_id, action, timeout_s): snapshot-save's
-- reply means the job STARTED; the capture is durable once the job is
-- CONCLUDED without an error. Two channels, events fast-path + query-jobs
-- ground truth:
--
--   * JOB_STATUS_CHANGE carries { id, status } only — NO error payload
--     (qapi/job.json). The error string lives in query-jobs (`JobInfo.
--     error`). A FAILED job passes through `aborting` before `concluded`
--     (running → aborting → concluded; success is waiting → pending →
--     concluded — no aborting, observed live on qemu 10.2).
--   * the loop reads the WHOLE buffer each round (the client's events(),
--     which does not consume): events that landed in a send's read window
--     sit in the buffer too, so they reach the loop on the next round
--     rather than being missed (a send's clear happens before ITS read
--     window, and every round reads before the next send). Every ~10
--     rounds we still ask query-jobs directly — ground truth regardless
--     of event delivery; the job row exists the whole time (snapshot jobs
--     are JOB_MANUAL_DISMISS, so a concluded job stays listed until
--     dismissed — `null` need not be awaited).
--   * once concluded-without-error is confirmed we job-dismiss (best
--     effort) so the row doesn't linger and future savevm job-ids can
--     repeat (a leftover concluded job makes the next savevm with the
--     same tag fail with "Job ID already in use").
--
-- Side effect accepted (documented): sends inside this waiter clear the
-- client's buffered events per send semantics (qmp.md). During a snapshot
-- the guest is quiesced; the in-flight events are our job's lifecycle and
-- STOP/RESUME only.
local function wait_for_job(client, h, job_id, action, timeout_s)
	local t = makac.time
	local deadline = t.now() + math.floor(timeout_s * t.ns_per_s)
	local saw_aborting = false
	local polls = 0

	-- check_jobs() -> done:boolean, err:string|nil : ask query-jobs how
	-- our job stands. done=true with err=nil is success; done=true with
	-- err set raises. A row with status "concluded" decides; anything else
	-- (running, absent) means "not done".
	local function check_jobs()
		local okq, res = pcall(client.send, client,
			{ { execute = "query-jobs" } }, { timeout_s = 10 })
		if not okq then
			error(("qemu:%s: VM '%s': query-jobs while waiting for snapshot job '%s' failed: %s")
				:format(action, h.name, job_id, tostring(res)), 0)
		end
		local jobs = res[1] and res[1]["return"]
		if type(jobs) ~= "table" then
			return false -- unexpected shape: keep waiting on events
		end
		for _, j in ipairs(jobs) do
			if j.id == job_id and (j.status == "concluded" or j.status == "null") then
				return true, (j.error ~= nil and tostring(j.error) or nil)
			end
		end
		return false
	end

	local function finish(outcome_err)
		-- best-effort dismiss so the concluded/failed row doesn't linger
		-- and block a later savevm of the same tag on this VM
		pcall(client.send, client,
			{ { execute = "job-dismiss", arguments = { id = job_id } } },
			{ timeout_s = 10 })
		if outcome_err == nil and saw_aborting then
			outcome_err = "the job passed through aborting before concluding"
		end
		if outcome_err ~= nil then
			error(("qemu:%s: VM '%s': snapshot job '%s' failed: %s"):format(
				action, h.name, job_id, outcome_err), 0)
		end
	end

	while true do
		local ok, e = pcall(client.poll, client, { timeout_s = 1 })
		if not ok then
			error(("qemu:%s: VM '%s': waiting for snapshot job '%s': %s")
				:format(action, h.name, job_id, tostring(e)), 0)
		end
		-- read the whole buffer every round (not only fresh events):
		-- send-window events sit in it as well, and reading does not
		-- consume. Re-scanning rounds is harmless: saw_aborting is sticky
		-- and a concluded job finishes (idempotently) again.
		local ok2, events = pcall(client.events, client)
		if not ok2 then
			error(("qemu:%s: VM '%s': waiting for snapshot job '%s': %s")
				:format(action, h.name, job_id, tostring(events)), 0)
		end
		for _, ev in ipairs(events) do
			if ev.name == "JOB_STATUS_CHANGE"
				and type(ev.data) == "table" and ev.data.id == job_id then
				if ev.data.status == "aborting" then
					saw_aborting = true
				end
				if ev.data.status == "concluded" or ev.data.status == "null" then
					-- event says done; ground-truth the error via query-jobs
					local done, jerr = check_jobs()
					finish(jerr or (ev.data.error ~= nil and tostring(ev.data.error) or nil))
					return -- durable (or failed above)
				end
			end
		end
		-- ground-truth fallback: ask query-jobs directly every ~10 rounds
		polls = polls + 1
		if polls % 10 == 0 then
			local done, jerr = check_jobs()
			if done then
				finish(jerr)
				return
			end
		end
		if t.now() > deadline then
			error(("qemu:%s: VM '%s': snapshot job '%s' did not complete within %ds")
				:format(action, h.name, job_id, timeout_s), 0)
		end
	end
end

-- qemu:savevm — capture a snapshot of a RUNNING VM under `with.tag`
-- (default: a timestamped tag) into the VM's writable block devices. The
-- guest keeps running. out.snapshot is the tag.
function M.savevm(with)
	with = with or {}
	if with.vm == nil then
		error("qemu:savevm: 'with.vm' is required: a VM handle (qemu:vm's out.handle) or a plain VM name", 2)
	end
	local tag = with.tag
	if tag == nil then
		tag = default_tag()
	elseif type(tag) ~= "string" or tag == "" then
		error(("qemu:savevm: 'with.tag' must be a non-empty string, got %s (%s)")
			:format(tostring(tag), type(tag)), 2)
	end
	local timeout_s = with.timeout_s
	if timeout_s == nil then
		timeout_s = 300
	elseif type(timeout_s) ~= "number" or timeout_s <= 0 then
		error(("qemu:savevm: 'with.timeout_s' must be a positive number, got %s")
			:format(tostring(timeout_s)), 2)
	end

	local h = handlelib.resolve(with.vm, with.run_dir)

	-- the VM must be RUNNING (handle.md's probe; it never raises on a
	-- down/wedged VM — it reports, and snapshots.md wants that report
	-- quoted in the failure).
	local p = handlelib.probe(h)
	if p.running ~= true then
		error(("qemu:savevm: VM '%s' must be running, but the probe reports: %s")
			:format(h.name, fmt_probe(p)), 0)
	end

	-- capture over the handle's per-run connection (opens one on demand,
	-- as the qmp actions do).
	local client = actions_qmp.connection("savevm", with)

	local devices = writable_devices(client, h, "savevm")
	local job_id = "savevm-" .. tag
	send1(client, h, {
		execute = "snapshot-save",
		arguments = {
			["job-id"] = job_id,
			tag = tag,
			vmstate = devices[1],
			devices = devices, -- includes the vmstate device (see above)
		},
	}, "savevm")
	wait_for_job(client, h, job_id, "savevm", timeout_s)

	return { changed = true, out = { snapshot = tag } }
end

-- qemu:loadvm is NOT here: it is qemu:vm's start/restart choreography
-- with one additional input, so it lives in actions_vm.lua (M.loadvm).

return M

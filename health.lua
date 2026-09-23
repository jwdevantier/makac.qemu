-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- makac.qemu health check (makac's design/doctor.md): the programs the
-- package's actions invoke, plus a self-check that its library modules load.

return function(health, pkg_name)
	local function on_path(bin)
		local ok, res = pcall(makac.exec, { "sh", "-c", "command -v " .. bin })
		if ok and res.code == 0 then
			local p = (res.stdout or ""):gsub("%s+$", "")
			if p ~= "" then return p end
		end
		return nil
	end

	health.start("programs")

	-- qemu-img builds every image (raw and the cloud-init overlay)
	local qemu_img = on_path("qemu-img")
	if qemu_img then
		health.ok("qemu-img found at " .. qemu_img)
	else
		health.error("qemu-img not found", "install qemu and put qemu-img on $PATH")
	end

	-- genisoimage is only needed by the cloud-init builder (the cidata ISO)
	local geniso = on_path("genisoimage")
	if geniso then
		health.ok("genisoimage found at " .. geniso)
	else
		health.warn("genisoimage not found",
			"needed only by the cloud-init builder; install cdrkit/genisoimage")
	end

	-- the guest qemu binary is supplied per workflow (`with.qemu_bin`), so it
	-- is only informational here
	for _, bin in ipairs({ "qemu-system-x86_64", "qemu-system-s390x" }) do
		local p = on_path(bin)
		if p then
			health.info(bin .. " found at " .. p)
		else
			health.info(bin .. " not on $PATH (fine when with.qemu_bin points at a build)")
		end
	end

	health.start("library")
	for _, mod in ipairs({ "qmp", "img", "serial" }) do
		local ok, err = pcall(require, pkg_name .. "/" .. mod)
		if ok then
			health.ok("require " .. pkg_name .. "/" .. mod)
		else
			health.error("cannot require " .. pkg_name .. "/" .. mod, tostring(err))
		end
	end
end

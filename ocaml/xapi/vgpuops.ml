(*
 * Copyright (C) 2006-2011 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
module D=Debug.Make(struct let name="vgpuops" end)
open D

open Listext
open Xstringext

type vgpu = {
	vgpu_ref: API.ref_VGPU;
	gpu_group_ref: API.ref_GPU_group;
	devid: int;
	other_config: (string * string) list;
	type_ref: API.ref_VGPU_type;
}

let vgpu_of_vgpu ~__context vm_r vgpu =
	let vgpu_r = Db.VGPU.get_record ~__context ~self:vgpu in
	{
		vgpu_ref = vgpu;
		gpu_group_ref = vgpu_r.API.vGPU_GPU_group;
		devid = int_of_string vgpu_r.API.vGPU_device;
		other_config = vgpu_r.API.vGPU_other_config;
		type_ref = vgpu_r.API.vGPU_type;
	}

let vgpus_of_vm ~__context vm_r =
	List.map (vgpu_of_vgpu ~__context vm_r) vm_r.API.vM_VGPUs

let create_passthrough_vgpu ~__context ~vm vgpu available_pgpus pcis =
	debug "Creating passthrough VGPUs";
	let compatible_pgpus = Db.GPU_group.get_PGPUs ~__context ~self:vgpu.gpu_group_ref in
	let pgpus = List.intersect compatible_pgpus available_pgpus in
	let rec choose_pgpu = function
		| [] -> None
		| pgpu :: remaining ->
			try
				Xapi_pgpu_helpers.assert_capacity_exists_for_VGPU_type ~__context
					~self:pgpu ~vgpu_type:vgpu.type_ref;
				Some (pgpu, Db.PGPU.get_PCI ~__context ~self:pgpu)
			with _ -> choose_pgpu remaining
	in
	match choose_pgpu pgpus with
	| None ->
		raise (Api_errors.Server_error (Api_errors.vm_requires_gpu, [
			Ref.string_of vm;
			Ref.string_of vgpu.gpu_group_ref
		]))
	| Some (pgpu, pci) ->
		Db.VGPU.set_scheduled_to_be_resident_on ~__context
			~self:vgpu.vgpu_ref ~value:pgpu;
		List.filter (fun g -> g <> pgpu) available_pgpus,
		pci :: pcis

let add_pcis_to_vm ~__context host vm passthru_vgpus =
	let pcis =
		if passthru_vgpus <> [] then begin
			let pgpus = Db.Host.get_PGPUs ~__context ~self:host in
			let _, pcis =
				List.fold_left
					(fun (pgpus, pcis) passthru_vgpu ->
						create_passthrough_vgpu ~__context ~vm passthru_vgpu pgpus pcis)
					(pgpus, []) passthru_vgpus
			in
			pcis
		end else
			[] in
	(* Add a platform key to the VM if any of the PCIs are integrated GPUs;
	 * otherwise remove the key. *)
	Db.VM.remove_from_platform ~__context
		~self:vm ~key:Xapi_globs.igd_passthru_key;
	if List.exists
		(fun pci ->
			let (_, pci_bus, _, _) = Pciops.pcidev_of_pci ~__context pci in
			(pci_bus = 0) && (Xapi_pci_helpers.igd_is_whitelisted ~__context pci))
		pcis
	then Db.VM.add_to_platform ~__context ~self:vm ~key:Xapi_globs.igd_passthru_key ~value:"true";
	(* The GPU PCI devices which xapi manages may have dependencies: *)
	let dependent_pcis = List.setify (List.flatten
		(List.map (fun pci -> Db.PCI.get_dependencies ~__context ~self:pci) pcis)) in
	let devs : (int * int * int * int) list = List.sort compare (List.map (Pciops.pcidev_of_pci ~__context) (pcis @ dependent_pcis)) in
	(* Add a hotplug ordering (see pcidevs_of_pci) *)
	let devs : ((int * (int * int * int * int))) list = List.rev (snd (List.fold_left (fun (i, acc) pci -> i + 1, (i, pci) :: acc) (0, []) devs)) in
	(* Update VM other_config for PCI passthrough *)
	(try Db.VM.remove_from_other_config ~__context ~self:vm ~key:Xapi_globs.vgpu_pci with _ -> ());
	let value = String.concat "," (List.map Pciops.to_string devs) in
	Db.VM.add_to_other_config ~__context ~self:vm ~key:Xapi_globs.vgpu_pci ~value

let create_virtual_vgpu ~__context host vm vgpu =
	debug "Creating virtual VGPUs";
	let available_pgpus = Db.Host.get_PGPUs ~__context ~self:host in
	let compatible_pgpus = Db.GPU_group.get_PGPUs ~__context ~self:vgpu.gpu_group_ref in
	let pgpus = List.intersect compatible_pgpus available_pgpus in
	(* Sort the pgpus in lists of equal optimality for vGPU placement based on
	 * the GPU groups allocation algorithm *)
	let sort_desc =
		match Db.GPU_group.get_allocation_algorithm ~__context ~self:vgpu.gpu_group_ref with
		| `depth_first -> false
		| `breadth_first -> true
	in
	let rec allocate_vgpu vgpu_type = function
		| [] -> None
		| pgpu :: remaining_pgpus ->
			try
				Xapi_pgpu_helpers.assert_capacity_exists_for_VGPU_type
					~__context ~self:pgpu ~vgpu_type;
				Some pgpu
			with _ -> allocate_vgpu vgpu_type remaining_pgpus
	in
	let sorted_pgpus = Helpers.sort_by_schwarzian ~descending:sort_desc
			(fun pgpu ->
			Helpers.call_api_functions ~__context (fun rpc session_id ->
					Client.Client.PGPU.get_remaining_capacity ~rpc ~session_id
					~self:pgpu ~vgpu_type:vgpu.type_ref))
			pgpus
	in
	match allocate_vgpu vgpu.type_ref sorted_pgpus with
	| None ->
		raise (Api_errors.Server_error (Api_errors.vm_requires_vgpu, [
			Ref.string_of vm;
			Ref.string_of vgpu.gpu_group_ref;
			Ref.string_of vgpu.type_ref
		]))
	| Some pgpu ->
		Db.VGPU.set_scheduled_to_be_resident_on ~__context
			~self:vgpu.vgpu_ref ~value:pgpu

let add_vgpus_to_vm ~__context host vm vgpus =
	(* Only support a maximum of one virtual GPU per VM for now. *)
	match vgpus with
	| [] -> ()
	| vgpu :: _ -> create_virtual_vgpu ~__context host vm vgpu

let vgpu_manual_setup_of_vm vm_r =
	List.mem_assoc Xapi_globs.vgpu_manual_setup_key vm_r.API.vM_platform &&
	(List.assoc Xapi_globs.vgpu_manual_setup_key vm_r.API.vM_platform = "true")

let create_vgpus ~__context host (vm, vm_r) hvm =
	let vgpus = vgpus_of_vm ~__context vm_r in
	if vgpus <> [] then begin
		if not hvm then
			raise (Api_errors.Server_error (Api_errors.feature_requires_hvm, ["vGPU- and GPU-passthrough needs HVM"]))
	end;
	let (passthru_vgpus, virtual_vgpus) =
		List.partition
			(fun v -> Xapi_vgpu.requires_passthrough ~__context ~self:v.vgpu_ref)
			vgpus
	in
	if virtual_vgpus <> [] && not (Pool_features.is_enabled ~__context Features.VGPU) then
		raise (Api_errors.Server_error (Api_errors.feature_restricted, []));
	add_pcis_to_vm ~__context host vm passthru_vgpus;
	if not (vgpu_manual_setup_of_vm vm_r)
	then add_vgpus_to_vm ~__context host vm virtual_vgpus

let list_pcis_for_passthrough ~__context ~vm =
	try
		let value = List.assoc Xapi_globs.vgpu_pci (Db.VM.get_other_config ~__context ~self:vm) in
		List.map Pciops.of_string (String.split ',' value)
	with _ -> []

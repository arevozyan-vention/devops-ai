terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/resource-group"
}

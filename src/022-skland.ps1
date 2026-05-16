####################
# skland
####################

function Invoke-SklandAttendance {
	param($Profiie, $Config, $Embed, $IsReusing)
	return Invoke-SkAttendanceCore -Provider 'skland' -Profile $Profiie -PlatformConfig $Config -Embed $Embed -IsReusing $IsReusing
}

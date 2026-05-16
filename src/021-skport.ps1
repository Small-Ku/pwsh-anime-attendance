####################
# skport
####################

function Invoke-SkportAttendance {
	param($Profiie, $Config, $Embed, $IsReusing)
	return Invoke-SkAttendanceCore -Provider 'skport' -Profile $Profiie -PlatformConfig $Config -Embed $Embed -IsReusing $IsReusing
}

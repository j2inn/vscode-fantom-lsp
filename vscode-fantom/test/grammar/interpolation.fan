class InterpolationTest
{
  Void test()
  {
    // Simple variable interpolation
    a := "value is $name"
    b := "value is $obj.field.sub"

    // Simple expression interpolation
    c := "hello ${name}"
    d := "value is ${expr + 1}"

    // Multiple interpolations in one string
    e := "${tagRef} == ${refId.toCode} and ${modelTag} == ${modelVal.toCode}"
    f := "${floorRef} == ${floorId.toCode} and ${floorModelTag} == ${modelId.toCode}"

    // Interpolation with method calls
    g := "id == ${schedId.toCode} and ${actionTag} == ${modelId.toCode}"
    h := "${entityRef} == ${entityId.toCode} and ${modelName} == ${modelVal.toCode}"

    // Interpolation with string concatenation
    i := "${prefix}${suffix}"
    j := "${modbusAddr}-${moduleId}"

    // Interpolation with member access
    k := "Error for [${connId.dis}]"
    l := "Data is `${value.typeof.name}` instead of `Str`"

    // Interpolation inside Err/throw
    m := "Invalid address: ${address}"
    n := "No config found for unit with ID ${unitId}"
    o := "There should be exactly 1 alarm for '$errorCode' instead of '${alarms.size()}'\n$alarms"

    // Interpolation with arithmetic
    p := "Unit ${idx + 1}"
    q := "IDU ${oduIdx + 1}-${iduIdx + 1}"

    // Simple dollar var in query strings
    r := "point and $model and $tag"
    s := "$refTag == ${tenantId.toCode}"

    // Static const with interpolation
    static const Str REF_TAG := "${EntityType.site}Ref"

    // Backtick interpolation in error messages
    t := "`${pointName}`: ${err.msg}"
    u := "`${pointName}`: ${value}"

    // Mixed dollar and dollar-brace
    v := "Setup $moduleName ${settingVal}..."
    w := "id == ${it.toCode}"

    // Interpolation with map/closure result
    x := "v${counter++}"

    // Arrow access in interpolation
    y := "${connTag} and ${refArg} == ${moduleRef.toCode}"

    // Interpolation at start and end
    z := "${prefix}Ref"
    aa := "point and ${modelId} == $id.toCode and ${modelTag}==$tagId.toCode"
  }
}

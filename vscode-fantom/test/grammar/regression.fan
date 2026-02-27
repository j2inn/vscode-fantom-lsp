using bacnetServerExt

class BacnetServer : IBacnetServer {

  static const Int START_INDEX := 100

  const Str[] COLS := [
    "objectId",
    "objectName",
  ]

  **
  ** Sorted list of columns that can be copy pasted into the documentation:
  ** It's composed by: BACNET_ELEMENTS_COLS+ENTITY_POINTS_COLS-COLS_TO_REMOVE
  **
  const static Str[] SORTED_COLS := [
    "device",
    "object",
  ]

  new make() {
    this.name = "test"
  }

  ** Get the list of equipments that can be exposed over BACnet.
  ** It's important to check the site id isn't null.
  Dict[] getExposableDevices() {
    if (this.siteId == null) {
      throw Err("Site id must not be null to get the exposable devices")
    }
    return getMainEquipsList().flatten
  }

  **
  ** getEntityBacnetDescription returns a Grid representation of Bacnet description for the specified
  ** entity. It considers whether the Bacnet server is enabled and if a valid bacnetServerDeviceRef is
  ** provided. The method merges Bacnet elements with specific entity points, sorts them, and removes
  ** unnecessary columns from the result Grid.
  **
  ** @param entityId The reference ID of the entity of interest.
  ** @param entityRefTagName The tag name associated with entity reference in points.
  ** @return Grid The processed Bacnet descriptions as a Grid.
  **
  private Grid getEntityBacnetDescription(Ref entityId) {
    return Etc.emptyGrid
  }
}

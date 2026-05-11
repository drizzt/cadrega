package app.lawnchair.util

import android.content.Context
import android.os.UserHandle
import android.os.UserManager
import com.android.launcher3.model.data.FolderInfo
import com.android.launcher3.model.data.ItemInfo
import com.android.launcher3.model.data.WorkspaceItemInfo
import com.android.launcher3.pm.UserCache

object PrivateSpaceVisibility {

    private fun privateUser(context: Context): UserHandle? {
        val userCache = UserCache.INSTANCE[context]
        return userCache.userProfiles.firstOrNull { userCache.getUserInfo(it).isPrivate }
    }

    private fun isQuietModeEnabled(context: Context, user: UserHandle): Boolean =
        context.getSystemService(UserManager::class.java)?.isQuietModeEnabled(user) == true

    @JvmStatic
    fun shouldHidePrivateProfile(context: Context): Boolean {
        val user = privateUser(context) ?: return false
        return isQuietModeEnabled(context, user)
    }

    @JvmStatic
    fun isPrivateProfileItem(context: Context, info: ItemInfo?): Boolean {
        if (info == null) return false
        val user = privateUser(context) ?: return false
        return info.user == user
    }

    @JvmStatic
    fun filterForBind(context: Context, items: List<ItemInfo>): List<ItemInfo> {
        if (!shouldHidePrivateProfile(context)) return items
        val user = privateUser(context) ?: return items
        val out = ArrayList<ItemInfo>(items.size)
        for (item in items) {
            if (item.user == user) continue
            if (item is FolderInfo) {
                val visible = item.getContents().filter { it.user != user }
                when (visible.size) {
                    0 -> continue
                    1 -> {
                        val only = visible[0]
                        if (only is WorkspaceItemInfo) {
                            val promoted = WorkspaceItemInfo(only).apply {
                                container = item.container
                                screenId = item.screenId
                                cellX = item.cellX
                                cellY = item.cellY
                                rank = item.rank
                            }
                            out.add(promoted)
                            continue
                        }
                    }
                }
            }
            out.add(item)
        }
        return out
    }
}

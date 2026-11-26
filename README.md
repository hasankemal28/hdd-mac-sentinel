# HDD Mac Sentinel

HDD Mac Sentinel, Mac’e bağlı harici depolama aygıtlarını gösteren Türkçe bir macOS uygulamasıdır. macOS 13 Ventura ve sonrası için derlenir. Uygulama Apple Silicon ve Intel Mac’leri destekler.

## Kullanım

1. [GitHub Releases](https://github.com/hasankemal28/hdd-mac-sentinel/releases/latest) sayfasından macOS ZIP dosyasını indirin. ZIP dosyasını açın ve **HDD Mac Sentinel.app** uygulamasını başlatın.
2. USB belleğinizi, SSD’nizi veya sabit diskinizi bağlayın ve sol listeden seçin.
3. SMART durumunu inceleyin. SMART verisi alınamıyorsa **Disk sağlığı → Dosya Sistemlerini Denetle** ile diskteki birimlerin dosya sistemi yapılarını denetleyin. GUID bölüm haritalı disklerde **Bölüm Haritasını Denetle** ile bölüm düzenini de kontrol edebilirsiniz.
4. Biçimlendirmek için yeni bir disk adı ve dosya sistemi seçin. **Diski Biçimlendir…** düğmesine basın. Onay ekranındaki model, kapasite ve birim adlarını kontrol edip **Diski Sil ve Biçimlendir** düğmesine basın.

**Biçimlendirme, seçili fiziksel diskteki tüm bölümleri ve dosyaları siler.** Uygulama GUID bölüm haritası oluşturur. exFAT Mac ve Windows ile, APFS güncel macOS sürümleriyle, Mac OS Genişletilmiş ise eski Mac sistemleriyle kullanım içindir.

SMART yalnızca macOS’a bu bilgiyi ileten aygıtlarda görünür. Bazı USB adaptörleri SMART verisini iletmez. Dosya sistemi denetimi her birim için sonucu gösterir. Yalnızca doğrulama yapar ve birimi geçici olarak ayırabilir. Kilitli veya macOS’un doğrulayamadığı birimlerin durumu raporda belirtilir. Bu sonuç dosya sistemiyle sınırlıdır. Diskin fiziksel durumu SMART gibi donanım tanılama verileriyle değerlendirilir.

Uygulama yerel olarak imzalanmıştır ve Apple noter onayı yoktur. macOS açılışı engellerse ve dosyaya güveniyorsanız **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç** seçeneğini kontrol edin. İşlemler oturum açmış kullanıcının izinleriyle çalışır. macOS bir işlemi reddederse hata metnini uygulama gösterir.

## Kaynak koddan derleme

Xcode Komut Satırı Araçları yüklü bir Mac’te bu klasörde `./build.sh` komutunu çalıştırın. Uygulama `dist` klasöründe oluşur. Başka bir çıktı klasörü için yolu ilk argüman olarak verin.

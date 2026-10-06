import { supabase } from './supabase.js'

export function getPosition() {
  return new Promise((resolve, reject) => {
    if (!('geolocation' in navigator)) {
      reject(new Error('Geolocalizacion no soportada'))
      return
    }
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      (err) => reject(err),
      { enableHighAccuracy: false, timeout: 10000, maximumAge: 300000 }
    )
  })
}

export async function detectCity() {
  const { lat, lng } = await getPosition()
  const { data, error } = await supabase.rpc('nearest_city', { p_lat: lat, p_lng: lng })
  if (error) throw error
  const city = data && data[0]
  if (!city || !city.within_radius) return { city: null, lat, lng }
  return { city, lat, lng }
}

export async function listActiveCities() {
  const { data, error } = await supabase
    .from('cities')
    .select('id, name')
    .eq('active', true)
    .order('name')
  if (error) throw error
  return data
}
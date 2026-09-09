export const A = () => (
  <div
    {/* 這個註解站在屬性列表裡，parser 會炸 */}
    style={{ color: 'red' }}
  />
)

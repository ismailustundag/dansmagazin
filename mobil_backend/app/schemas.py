from typing import List, Optional
from pydantic import BaseModel


class MenuItem(BaseModel):
    key: str
    title: str
    icon: str
    route: str
    badge: Optional[int] = None


class MobileMenuResponse(BaseModel):
    items: List[MenuItem]
